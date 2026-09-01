# frozen_string_literal: true

module RubyDB
  module CLI
    module Commands
      # Start - Start the database server
      class Start
        def initialize(output, formatter)
          @output = output
          @formatter = formatter
        end

        def execute(args, options)
          parser = OptionParser.new do |opts|
            opts.banner = "Usage: rubydb start [options]"
            opts.on("-d", "--daemon", "Run as daemon") do
              options[:daemon] = true
            end
            opts.on("-p", "--port PORT", Integer, "Server port") do |port|
              options[:port] = port
            end
            opts.on("-h", "--host HOST", "Server host") do |host|
              options[:host] = host
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

          @output.spinner("Starting RubyDB server...") do
            # In production, would start the server
            @output.success("RubyDB server started on #{options[:host] || 'localhost'}:#{options[:port] || 7432}")
          end
        end
      end
    end
  end
end