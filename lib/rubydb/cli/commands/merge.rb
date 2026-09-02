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
            opts.on("--database PATH", "Database path") { |path| options[:database] = path }
            opts.on("--branch-dir DIR", "Branch metadata directory") { |path| options[:branch_dir] = path }
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
          database = RubyDB::Database.new(options[:database] || "data/rubydb.rdb", auto_connect: false).connect
          manager = RubyDB::Branching::BranchManager.new(
            database.engine,
            branch_dir: options[:branch_dir] || "branches"
          )
          merger = RubyDB::Branching::Merge.new(database.engine, manager,
                                                strategy: (options[:strategy] || :fast_forward))
          result = nil
          @output.spinner("Merging #{source} into #{target}...") do
            result = merger.merge(source, target, abort_on_conflict: true)
          end
          raise result[:error] || result[:message] unless result[:success]
          @output.success(result[:message] || "Merge completed successfully")
          0
        ensure
          database&.close
        end
      end
    end
  end
end
