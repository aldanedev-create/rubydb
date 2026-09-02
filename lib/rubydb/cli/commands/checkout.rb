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
            opts.on("--database PATH", "Database path") { |path| options[:database] = path }
            opts.on("--branch-dir DIR", "Branch metadata directory") { |path| options[:branch_dir] = path }
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

          database = RubyDB::Database.new(options[:database] || "data/rubydb.rdb", auto_connect: false).connect
          manager = RubyDB::Branching::BranchManager.new(
            database.engine,
            branch_dir: options[:branch_dir] || "branches"
          )
          selected = options[:create] || branch
          result = manager.create_branch(selected, from: manager.current_branch_name) if options[:create]
          raise result[:error] if result && !result[:success]
          result = manager.checkout(selected)
          raise result[:error] unless result[:success]
          @output.success("Switched to branch #{selected}")
          0
        ensure
          database&.close
        end
      end
    end
  end
end
