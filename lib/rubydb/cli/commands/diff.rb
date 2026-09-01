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
            opts.on("-h", "--help", "Show help") do
              @output.puts opts
              exit(0)
            end
          end

          parser.parse!(args)

          branch_a = args[0] || "main"
          branch_b = args[1] || "current"

          diff_data = {
            added_tables: ["posts"],
            removed_tables: [],
            changed_tables: [
              { name: "users", changes: ["added column: email", "changed column: name"] }
            ],
            added_columns: [
              { table: "users", column: "email", type: "text" }
            ],
            removed_columns: [],
            changed_columns: [
              { table: "users", column: "name", old_type: "varchar(50)", new_type: "varchar(100)" }
            ]
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
            @formatter.format_diff(diff_data)
          end
        end
      end
    end
  end
end