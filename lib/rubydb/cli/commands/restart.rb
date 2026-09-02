# frozen_string_literal: true

require "optparse"

module RubyDB
  module CLI
    module Commands
      # Sends a restart signal to the process recorded by the PID file.
      class Restart
        def initialize(output, formatter)
          @output = output
          @formatter = formatter
        end

        def execute(args, options)
          parser = OptionParser.new do |opts|
            opts.banner = "Usage: rubydb restart [options]"
            opts.on("--pid-file FILE", "PID file") { |file| options[:pid_file] = file }
            opts.on("--force", "Send KILL instead of TERM") { options[:force] = true }
            opts.on("-h", "--help", "Show help") { @output.puts opts; return 0 }
          end
          parser.parse!(args)

          pid_file = options[:pid_file] || "rubydb.pid"
          raise "PID file not found: #{pid_file}" unless File.file?(pid_file)
          pid = Integer(File.read(pid_file).strip, 10)
          Process.kill(0, pid)
          Process.kill(options[:force] ? "KILL" : "TERM", pid)
          @output.success("RubyDB restart signal sent to PID #{pid}")
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
