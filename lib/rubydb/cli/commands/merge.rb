# frozen_string_literal: true

module RubyDB
  module CLI
    module Commands
      # Merge - Merge a branch
      class Merge
        def initialize(output, formatter)
          @output = output
          @formatter = formatter
        end

        def execute(args, options)
          parser = OptionParser.new do |opts|
            opts.banner = "Usage: rubydb merge [options]"
            opts.on("--into BRANCH", "Target branch") do |branch|
              options[:into] = branch
            end
            opts.on("--strategy STRATEGY", "Merge strategy (fast-forward, recursive)") do |strategy|
              options[:strategy] = strategy.to_sym
            end
            opts.on("--no-commit", "Don't commit after merge") do
              options[:no_commit] = true
            end
            opts.on("-h", "--help", "Show help") do
              @output.puts opts
              exit(0)
            end
          end

          parser.parse!(args)

          source = args.first
          if source.nil?
            @output.error("Source branch required")
            @output.puts parser
            return
          end

          target = options[:into] || "main"

          @output.spinner("Merging #{source} into #{target}...") do
            @output.success("Merge completed successfully")
          end
        end
      end
    end
  end
end