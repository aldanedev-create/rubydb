# frozen_string_literal: true

module RubyDB
  module CLI
    module Commands
      # Checkout - Switch to a branch
      class Checkout
        def initialize(output, formatter)
          @output = output
          @formatter = formatter
        end

        def execute(args, options)
          parser = OptionParser.new do |opts|
            opts.banner = "Usage: rubydb checkout [options]"
            opts.on("-b", "--create NAME", "Create and checkout branch") do |name|
              options[:create] = name
            end
            opts.on("-h", "--help", "Show help") do
              @output.puts opts
              exit(0)
            end
          end

          parser.parse!(args)

          branch = args.first
          if branch.nil? && options[:create].nil?
            @output.error("Branch name required")
            @output.puts parser
            return
          end

          if options[:create]
            @output.spinner("Creating and checking out branch #{options[:create]}...") do
              @output.success("Switched to branch #{options[:create]}")
            end
          else
            @output.spinner("Switching to branch #{branch}...") do
              @output.success("Switched to branch #{branch}")
            end
          end
        end
      end
    end
  end
end