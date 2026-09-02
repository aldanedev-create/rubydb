# frozen_string_literal: true

module RubyDB
  module CLI
    module Commands
      # Doctor - Run health checks
      class Doctor
        def initialize(output, formatter)
          @output = output
          @formatter = formatter
        end

        def execute(args, options)
          parser = OptionParser.new do |opts|
            opts.banner = "Usage: rubydb doctor [options]"
            opts.on("--fix", "Attempt to fix issues") do
              options[:fix] = true
            end
            opts.on("--quick", "Quick check only") do
              options[:quick] = true
            end
            opts.on("--json", "Output as JSON") do
              options[:json] = true
            end
            opts.on("-h", "--help", "Show help") do
              @output.puts opts
              exit(0)
            end
          end

          parser.parse!(args)

          config = RubyDB::Configuration::Config.instance
          db_path = config.get("storage.data_dir") || "data/rubydb.rdb"
          checks = []
          engine = nil

          begin
            started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            engine = RubyDB::Storage::Engine.new(db_path, auto_vacuum: false)
            latency_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round(2)
            checks << { name: "Connection", passed: true, details: { database: db_path, latency_ms: latency_ms } }
            checks << { name: "Storage", passed: engine.storage_manager.open?, details: engine.storage_manager.stats }
            checks << { name: "WAL", passed: !engine.wal.nil?, details: engine.wal.stats }
            unless options[:quick]
              checks << { name: "Indexes", passed: !engine.index_manager.nil?, details: engine.index_manager.stats }
            end
          rescue => e
            checks << { name: "Connection", passed: false, errors: [e.message] }
          ensure
            engine&.close if engine&.open?
          end

          results = {
            passed: checks.all? { |check| check[:passed] },
            total_count: checks.size,
            passed_count: checks.count { |check| check[:passed] },
            checks: checks
          }

          if options[:json]
            @output.json(results)
          else
            @formatter.format_doctor(results)

            if options[:fix] && !results[:passed]
              @output.puts "\nAutomatic repair is not available for the reported checks; no changes were made.", :yellow
            end
          end
        end
      end
    end
  end
end
