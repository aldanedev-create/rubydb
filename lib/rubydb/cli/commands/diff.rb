# frozen_string_literal: true

module RubyDB
  module CLI
    module Commands
      # Diff - Show differences between branches
      class Diff
        def initialize(output, formatter)
          @output = output
          @formatter = formatter
        end

        def execute(args, options)
          parser = OptionParser.new do |opts|
            opts.banner = "Usage: rubydb diff [options]"
            opts.on("--table TABLE", "Only show differences for a table") do |table|
              options[:table] = table
            end
          opts.on("--summary", "Show summary only") do
            options[:summary] = true
          end
            opts.on("--database PATH", "Database path") { |path| options[:database] = path }
            opts.on("--branch-dir DIR", "Branch metadata directory") { |path| options[:branch_dir] = path }
            opts.on("-h", "--help", "Show help") do
              @output.puts opts
              exit(0)
            end
          end

          parser.parse!(args)

          branch_a = args[0] || "main"
          branch_b = args[1] || "current"

          database = RubyDB::Database.new(options[:database] || "data/rubydb.rdb", auto_connect: false).connect
          manager = RubyDB::Branching::BranchManager.new(
            database.engine,
            branch_dir: options[:branch_dir] || "branches"
          )
          branch_b = manager.current_branch_name || "main" if branch_b == "current"
          result = RubyDB::Branching::Diff.new(database.engine, manager).diff(
            branch_a, branch_b, type: RubyDB::Branching::Diff::DIFF_ALL,
            tables: (options[:table] && [options[:table]])
          )
          raise result[:error] unless result[:success]

          changes = result[:changes]
          diff_data = {
            added_tables: [], removed_tables: [], changed_tables: [],
            added_columns: [], removed_columns: [], changed_columns: [],
            changes: changes
          }

          if options[:summary]
            @output.puts "Differences between #{branch_a} and #{branch_b}:"
            @output.puts "  Added tables: #{diff_data[:added_tables].size}"
            @output.puts "  Removed tables: #{diff_data[:removed_tables].size}"
            @output.puts "  Changed tables: #{diff_data[:changed_tables].size}"
            @output.puts "  Added columns: #{diff_data[:added_columns].size}"
            @output.puts "  Removed columns: #{diff_data[:removed_columns].size}"
            @output.puts "  Changed columns: #{diff_data[:changed_columns].size}"
          else
            @output.puts "Differences between #{branch_a} and #{branch_b}:"
            @output.puts "  Added changes: #{changes[:added].size}"
            @output.puts "  Removed changes: #{changes[:removed].size}"
            changes.each do |kind, entries|
              entries.each { |entry| @output.puts "  #{kind}: #{entry.inspect}" }
            end
          end
          0
        ensure
          database&.close
        end
      end
    end
  end
end
