# frozen_string_literal: true

require "base64"
require "bigdecimal"
require "csv"
require "json"
require "open3"
require "optparse"
require "tempfile"
require "time"

module RubyDB
  module CLI
    module Commands
      # Export creates a durable JSONL or CSV extract. Go is the default when
      # its bundled, checksum-verified tool is available; --engine ruby is a
      # deliberately simple parity oracle and recovery fallback.
      class Export
        FORMATS = %w[jsonl csv].freeze
        ENGINES = %w[auto go ruby].freeze

        def initialize(output, formatter)
          @output = output
          @formatter = formatter
        end

        def execute(args, options)
          export_options = {
            format: "jsonl",
            engine: "auto",
            workers: 0,
            max_rows: 0,
            where: []
          }
          parser = option_parser(export_options)
          parser.parse!(args)
          raise ArgumentError, "Unexpected export arguments: #{args.join(" ")}" unless args.empty?
          raise ArgumentError, "--database, --table, and --out are required" unless export_options.values_at(:database, :table, :out).all?
          raise ArgumentError, "--format must be one of: #{FORMATS.join(", ")}" unless FORMATS.include?(export_options[:format])
          raise ArgumentError, "--engine must be one of: #{ENGINES.join(", ")}" unless ENGINES.include?(export_options[:engine])
          raise ArgumentError, "--workers and --max-rows must be zero or greater" if export_options[:workers].negative? || export_options[:max_rows].negative?

          engine = RubyDB::Storage::Engine.new(export_options[:database], accelerator: accelerator_config(options))
          columns = selected_columns(engine, export_options[:table], export_options[:columns])
          tool = engine.accelerator.manager.verified_tool_binary
          selected_engine = choose_engine(export_options[:engine], tool)
          if selected_engine == "go"
            export_with_go(engine, tool, columns, export_options)
          else
            export_with_ruby(engine, columns, export_options)
          end
          @output.success("Exported #{export_options[:table]} to #{export_options[:out]} (#{selected_engine})")
          0
        ensure
          engine&.close if engine&.open?
        end

        private

        def option_parser(options)
          OptionParser.new do |opts|
            opts.banner = "Usage: rubydb export --database PATH --table NAME --out FILE [options]"
            opts.on("--database PATH", "Embedded database path") { |value| options[:database] = value }
            opts.on("--table NAME", "Table to export") { |value| options[:table] = value }
            opts.on("--out FILE", "New output file (never overwritten)") { |value| options[:out] = value }
            opts.on("--format FORMAT", FORMATS, "Output format: jsonl or csv") { |value| options[:format] = value }
            opts.on("--columns LIST", "Comma-separated output columns (default: all)") { |value| options[:columns] = value }
            opts.on("--where CLAUSE", "Filter: 'column eq value'; repeatable") { |value| options[:where] << value }
            opts.on("--workers N", Integer, "Go snapshot page workers (default: CPU, max 8)") { |value| options[:workers] = value }
            opts.on("--max-rows N", Integer, "Fail instead of writing more than N rows (0 is unlimited)") { |value| options[:max_rows] = value }
            opts.on("--engine ENGINE", ENGINES, "auto (default), go, or ruby") { |value| options[:engine] = value }
            opts.on("-h", "--help", "Show help") { @output.puts opts; exit(0) }
          end
        end

        def accelerator_config(global_options)
          configured = RubyDB::Configuration::Config.instance.to_hash[:accelerator]
          config = configured.is_a?(Hash) ? configured.dup : {}
          config[:mode] = global_options[:accelerator_mode] if global_options[:accelerator_mode]
          config
        end

        def selected_columns(engine, table, requested)
          available = engine.table_columns(table)
          raise DatabaseError, "Table '#{table}' does not exist" if available.empty?
          return available if requested.nil? || requested.empty?

          requested.split(",").map(&:strip).reject(&:empty?).map do |name|
            available.find { |column| column.name.to_s.casecmp?(name) } ||
              raise(DatabaseError, "Unknown column '#{name}' on '#{table}'")
          end
        end

        def choose_engine(requested, tool)
          return "ruby" if requested == "ruby"
          return "go" if requested == "go" && tool
          return "go" if requested == "auto" && tool

          raise Accelerator::UnavailableError.new("RubyDB Go export tool is unavailable or failed checksum verification", code: "tool_missing") if requested == "go"

          "ruby"
        end

        def export_with_go(engine, tool, columns, options)
          ensure_new_output!(options[:out])
          engine.with_export_snapshot do |snapshot|
            Tempfile.create(["rubydb-export-", ".json"], File.dirname(options[:out])) do |manifest|
              manifest.binmode
              manifest.write(JSON.generate(snapshot))
              manifest.flush
              manifest.fsync
              manifest.close

              command = [tool, "export", "--manifest", manifest.path, "--table", options[:table].to_s,
                "--format", options[:format], "--out", File.expand_path(options[:out]),
                "--columns", columns.map { |column| column.name.to_s }.join(","),
                "--workers", options[:workers].to_s, "--max-rows", options[:max_rows].to_s]
              options[:where].each { |clause| command.concat(["--where", clause]) }
              stdout, stderr, status = Open3.capture3(*command)
              next if status.success?

              message = stderr.to_s.strip
              message = stdout.to_s.strip if message.empty?
              raise StorageError, "Go export failed: #{message.empty? ? "unknown error" : message}"
            end
          end
        end

        def export_with_ruby(engine, columns, options)
          ensure_new_output!(options[:out])
          filters = options[:where].map { |clause| parse_filter(clause) }
          # RubyDB's physical tuple decoder needs schema-order definitions to
          # advance across every field. Read the complete schema, then apply
          # the output projection below; passing a reordered subset would
          # decode later values at the wrong byte offset.
          available = engine.table_columns(options[:table])
          filters.each do |filter|
            column = available.find { |candidate| candidate.name.to_s.casecmp?(filter[:column]) } ||
              raise(DatabaseError, "Unknown filter column '#{filter[:column]}' on '#{options[:table]}'")
            filter[:type] = column.type_class
          end
          atomic_output(options[:out]) do |file|
            writer = options[:format] == "csv" ? CSV.new(file, row_sep: "\n") : nil
            exported_rows = 0
            writer&.<< columns.map { |column| column.name.to_s }
            engine.with_export_rows(options[:table], available) do |row|
              next unless filters.all? { |filter| filter_matches?(row, filter) }

              exported_rows += 1
              raise StorageError, "Export exceeds configured row limit" if options[:max_rows].positive? && exported_rows > options[:max_rows]

              if writer
                writer << columns.map { |column| csv_value(export_value(row_value(row, column.name), column.type_class)) }
              else
                payload = columns.each_with_object({}) do |column, object|
                  object[column.name.to_s] = export_value(row_value(row, column.name), column.type_class)
                end
                file.write(JSON.generate(payload))
                file.write("\n")
              end
            end
            writer&.flush
            raise StorageError, "Ruby CSV export failed: #{writer.error.message}" if writer&.error
          end
        end

        def ensure_new_output!(path)
          raise StorageError, "Output file already exists: #{path}" if File.exist?(path)
          raise StorageError, "Output parent directory does not exist: #{File.dirname(path)}" unless Dir.exist?(File.dirname(path))
        end

        def atomic_output(path)
          partial = "#{path}.partial"
          file = File.open(partial, File::WRONLY | File::CREAT | File::EXCL, 0o600)
          # JSONL and CSV use LF on every platform so the Ruby oracle and Go
          # exporter are byte-for-byte comparable; Windows text mode would
          # otherwise rewrite each newline to CRLF.
          file.binmode
          begin
            yield file
            file.flush
            file.fsync
            file.close
            File.rename(partial, path)
          ensure
            file.close unless file.closed?
            File.delete(partial) if File.file?(partial)
          end
        end

        def parse_filter(clause)
          column, operator, raw = clause.to_s.strip.split(/\s+/, 3)
          valid = %w[eq ne lt lte gt gte like is_null is_not_null]
          raise ArgumentError, "Invalid --where #{clause.inspect}" unless column && valid.include?(operator)
          raise ArgumentError, "--where #{operator} does not take a value" if %w[is_null is_not_null].include?(operator) && raw
          raise ArgumentError, "--where #{operator} requires a value" unless raw || %w[is_null is_not_null].include?(operator)

          value = JSON.parse(raw) if raw
          {column: column.split(".").last, operator: operator, value: value}
        rescue JSON::ParserError
          {column: column.split(".").last, operator: operator, value: raw}
        end

        def filter_matches?(row, filter)
          value = filter_value(row_value(row, filter[:column]), filter[:type])
          expected = filter_expected_value(filter[:value], filter[:type])
          case filter[:operator]
          when "eq" then value == expected
          when "ne" then value != expected
          when "lt" then value && expected && value < expected
          when "lte" then value && expected && value <= expected
          when "gt" then value && expected && value > expected
          when "gte" then value && expected && value >= expected
          when "like" then value && File.fnmatch?(expected.to_s.tr("%", "*").tr("_", "?"), value.to_s)
          when "is_null" then value.nil?
          when "is_not_null" then !value.nil?
          end
        rescue ArgumentError, TypeError
          false
        end

        def row_value(row, name)
          return row[name] if row.key?(name)

          row[name.to_sym]
        end

        # Storage deserializes temporal/decimal/UUID values as Ruby objects,
        # while command-line values arrive as JSON scalars. Normalize the
        # comparable representation so filters such as a timestamp range have
        # the same semantics in the Ruby fallback and Go page streamer.
        def filter_value(value, type)
          case type.to_s.downcase
          when "decimal", "date", "time", "timestamp", "uuid", "blob"
            export_value(value, type)
          else
            value
          end
        end

        def filter_expected_value(value, type)
          return value if value.nil?

          case type.to_s.downcase
          when "decimal", "date", "time", "timestamp", "uuid", "blob"
            value.to_s
          else
            value
          end
        end

        def export_value(value, type)
          return nil if value.nil?

          case type.to_s.downcase
          when "blob"
            Base64.strict_encode64(value.to_s.b)
          when "decimal"
            value.is_a?(BigDecimal) ? value.to_s("F") : value.to_s
          when "date"
            value.respond_to?(:iso8601) ? value.iso8601 : value.to_s
          when "time"
            value.utc.strftime("%Y-%m-%dT%H:%M:%S.%6NZ")
          when "timestamp"
            value.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
          when "float"
            return "NaN" if value.respond_to?(:nan?) && value.nan?
            return "Infinity" if value.respond_to?(:infinite?) && value.infinite? == 1
            return "-Infinity" if value.respond_to?(:infinite?) && value.infinite? == -1
            return "-0" if value == 0.0 && (1.0 / value).negative?
            value
          else
            value
          end
        end

        def csv_value(value)
          case value
          when nil then ""
          when Hash, Array then JSON.generate(value)
          else value.to_s
          end
        end
      end
    end
  end
end
