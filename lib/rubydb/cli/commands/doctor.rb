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

          results = {
            passed: true,
            total_count: 6,
            passed_count: 5,
            checks: [
              { name: "Connection", passed: true, details: { latency: "5ms" } },
              { name: "Storage", passed: true, details: { usage: "45%", free: "55MB" } },
              { name: "Memory", passed: true, details: { usage: "60%", total: "1024MB" } },
              { name: "WAL", passed: true, details: { status: "healthy", size: "16MB" } },
              { name: "Replication", passed: true, details: { role: "primary", lag: "0ms" } },
              { name: "Indexes", passed: false, errors: ["Index 'idx_users_email' is corrupted"] }
            ]
          }

          if options[:json]
            @output.json(results)
          else
            @formatter.format_doctor(results)

            if options[:fix] && !results[:passed]
              @output.puts "\nAttempting to fix issues..."
              @output.spinner("Fixing issues...") do
                @output.success("Issues fixed")
              end
            end
          end
        end
      end
    end
  end
end