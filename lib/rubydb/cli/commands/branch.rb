# frozen_string_literal: true

require "optparse"

module RubyDB
  module CLI
    module Commands
      # Branch - Manage database branches
      class Branch
        def initialize(output, formatter)
          @output = output
          @formatter = formatter
        end

        def execute(args, options)
          parser = OptionParser.new do |opts|
            opts.banner = "Usage: rubydb branch [options]"
            opts.on("-l", "--list", "List branches") do
              options[:list] = true
            end
            opts.on("-c", "--create NAME", "Create branch") do |name|
              options[:create] = name
            end
            opts.on("-d", "--delete NAME", "Delete branch") do |name|
              options[:delete] = name
            end
            opts.on("--from BRANCH", "Create from branch") do |branch|
              options[:from] = branch
            end
            opts.on("--database PATH", "Database path") { |path| options[:database] = path }
            opts.on("--branch-dir DIR", "Branch metadata directory") { |path| options[:branch_dir] = path }
            opts.on("-h", "--help", "Show help") do
              @output.puts opts
              exit(0)
            end
          end

          parser.parse!(args)

          database = RubyDB::Database.new(options[:database] || "data/rubydb.rdb", auto_connect: false).connect
          manager = RubyDB::Branching::BranchManager.new(
            database.engine,
            branch_dir: options[:branch_dir] || "branches"
          )

          if options[:list] || (args.empty? && !options[:create] && !options[:delete])
            @formatter.format_branches(manager.list_branches)
            return 0
          end

          if options[:create]
            from = options[:from] || "main"
            result = manager.create_branch(options[:create], from: from)
            raise result[:error] unless result[:success]
            @output.success("Branch #{options[:create]} created")
            return 0
          end

          if options[:delete]
            result = manager.delete_branch(options[:delete])
            raise result[:error] unless result[:success]
            @output.success("Branch #{options[:delete]} deleted")
            return 0
          end
          raise "Specify --list, --create, or --delete"
        ensure
          database&.close
        end
      end
    end
  end
end
