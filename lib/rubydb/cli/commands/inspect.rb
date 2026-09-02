# frozen_string_literal: true

module RubyDB
  module CLI
    module Commands
      # Inspect - Inspect database internals
      class Inspect
        def initialize(output, formatter)
          @output = output
          @formatter = formatter
        end

        def execute(args, options)
          parser = OptionParser.new do |opts|
            opts.banner = "Usage: rubydb inspect [options]"
            opts.on("-t", "--table TABLE", "Inspect specific table") do |table|
              options[:table] = table
            end
            opts.on("--pages", "Show page information") do
              options[:pages] = true
            end
            opts.on("--indexes", "Show index information") do
              options[:indexes] = true
            end
            opts.on("--stats", "Show statistics") do
              options[:stats] = true
            end
            opts.on("--wal", "Show WAL information") do
              options[:wal] = true
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
          stats = engine.stats

          if options[:table]
            table = options[:table]
            raise "Table '#{table}' does not exist" unless engine.table_exists?(table)
            columns = engine.table_columns(table)
            @output.heading("Table: #{table}", 2)
            @output.puts "Columns:"
            columns.each { |column| @output.puts "  #{column.name}: #{column.type_class}" }
            @output.puts "\nRows: #{engine.select_rows(table, columns).size}"
          end

          if options[:pages]
            @output.heading("Pages", 2)
            @output.puts "Total pages: #{stats[:page_count]}"
            @output.puts "Used pages: #{stats[:used_pages]}"
            @output.puts "Free pages: #{stats[:free_pages]}"
          end

          if options[:indexes]
            @output.heading("Indexes", 2)
            @output.puts "Index statistics: #{engine.index_manager.stats.inspect}"
          end

          if options[:stats]
            @output.heading("Statistics", 2)
            stats.each { |key, value| @output.puts "#{key}: #{value}" }
          end

          if options[:wal]
            @output.heading("WAL Information", 2)
            wal_files = engine.wal_files
            wal_size = wal_files.sum { |file| File.size(file) }
            @output.puts "WAL enabled: #{!wal_files.empty?}"
            @output.puts "WAL files: #{wal_files.size}"
            @output.puts "WAL size: #{wal_size} bytes"
          end

          if !options[:table] && !options[:pages] && !options[:indexes] && !options[:stats] && !options[:wal]
            @output.heading("Database Inspection", 1)
            @output.puts "Version: #{RubyDB::VERSION}"
            @output.puts "Tables: #{stats[:table_count]}"
            @output.puts "Total pages: #{stats[:page_count]}"
            @output.puts "Database size: #{File.size(engine.path)} bytes"
            @output.puts "Cache hit rate: #{stats[:cache_hit_rate]}"
          end
          0
        ensure
          database&.close
        end
      end
    end
  end
end
