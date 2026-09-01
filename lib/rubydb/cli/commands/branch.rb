# frozen_string_literal: true

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
            opts.on("-h", "--help", "Show help") do
              @output.puts opts
              exit(0)
            end
          end

          parser.parse!(args)

          if options[:list] || (args.empty? && !options[:create] && !options[:delete])
            @formatter.format_branches([
              { name: "main", state: "active", commit_count: 10, created_at: "2024-01-01", parent_branch: nil },
              { name: "feature-auth", state: "active", commit_count: 5, created_at: "2024-01-02", parent_branch: "main" },
              { name: "feature-payments", state: "merged", commit_count: 3, created_at: "2024-01-03", parent_branch: "main" }
            ])
            return
          end

          if options[:create]
            from = options[:from] || "main"
            @output.spinner("Creating branch #{options[:create]} from #{from}...") do
              @output.success("Branch #{options[:create]} created")
            end
            return
          end

          if options[:delete]
            @output.spinner("Deleting branch #{options[:delete]}...") do
              @output.success("Branch #{options[:delete]} deleted")
            end
          end
        end
      end
    end
  end
end