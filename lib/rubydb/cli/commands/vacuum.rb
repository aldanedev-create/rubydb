# frozen_string_literal: true

module RubyDB
  module CLI
    module Commands
      # Vacuum - Vacuum the database
      class Vacuum
        def initialize(output, formatter)
          @output = output
          @formatter = formatter
        end

        def execute(args, options)
          parser = OptionParser.new do |opts|
            opts.banner = "Usage: rubydb vacuum [options]"
            opts.on("--full", "Full vacuum (reclaim space)") do
              options[:full] = true
            end
            opts.on("--analyze", "Analyze after vacuum") do
              options[:analyze] = true
            end
            opts.on("--table TABLE", "Vacuum specific table") do |table|
              options[:table] = table
            end
            opts.on("--dry-run", "Show what would be vacuumed") do
              options[:dry_run] = true
            end
            opts.on("--database PATH", "Database path") { |path| options[:database] = path }
            opts.on("-h", "--help", "Show help") do
              @output.puts opts
              exit(0)
            end
          end

          parser.parse!(args)

          database = RubyDB::Database.new(options[:database] || "data/rubydb.rdb", auto_connect: false).connect
          engine = database.engine

          if options[:dry_run]
            @output.info("Would vacuum:")
            stats = engine.stats
            @output.puts("  - Current rows: #{stats[:row_count]}")
            @output.puts("  - Tables affected: #{stats[:table_count]}")
            @output.puts("  - Cleanup will respect active transaction snapshots")
            return 0
          end

          result = engine.vacuum
          @output.success("Vacuum completed. Removed #{result[:removed]} rows; #{result[:total_rows]} rows remain.")
          0
        ensure
          database&.close
        end
      end
    end
  end
end
