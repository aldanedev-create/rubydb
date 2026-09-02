# frozen_string_literal: true

require "optparse"

module RubyDB
  module CLI
    module Commands
      # Stop - Stop the database server
      class Stop
        def initialize(output, formatter)
          @output = output
          @formatter = formatter
        end

        def execute(args, options)
          parser = OptionParser.new do |opts|
            opts.banner = "Usage: rubydb stop [options]"
            opts.on("-f", "--force", "Force stop") do
              options[:force] = true
            end
            opts.on("--pid-file FILE", "PID file") do |file|
              options[:pid_file] = file
            end
            opts.on("-h", "--help", "Show help") do
              @output.puts opts
              exit(0)
            end
          end

          parser.parse!(args)

          pid_file = options[:pid_file] || "rubydb.pid"
          raise "PID file not found: #{pid_file}" unless File.file?(pid_file)
          pid = Integer(File.read(pid_file).strip, 10)
          Process.kill(0, pid)
          Process.kill(options[:force] ? "KILL" : "TERM", pid)
          @output.success("RubyDB server stop signal sent to PID #{pid}")
          0
        rescue Errno::ESRCH
          raise "RubyDB process #{pid} is not running"
        rescue ArgumentError
          raise "Invalid PID in #{pid_file}"
        end
      end
    end
  end
end
