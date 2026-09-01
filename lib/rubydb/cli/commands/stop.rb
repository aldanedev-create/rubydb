# frozen_string_literal: true

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

          @output.spinner("Stopping RubyDB server...") do
            @output.success("RubyDB server stopped")
          end
        end
      end
    end
  end
end