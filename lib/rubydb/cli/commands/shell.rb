# frozen_string_literal: true

require "readline"
require "json"

module RubyDB
  module CLI
    module Commands
      class Shell
        def initialize(output, formatter)
          @output = output
          @formatter = formatter
          @history_file = File.expand_path("~/.rubydb_history")
          @connected = false
          @engine = nil
          @current_database = nil
          @transaction = nil
        end

        def execute(args, options)
          parser = OptionParser.new do |opts|
            opts.banner = "Usage: rubydb shell [options]"
            opts.on("-d", "--database NAME", "Database name") do |name|
              options[:database] = name
            end
            opts.on("-h", "--host HOST", "Server host") do |host|
              options[:host] = host
            end
            opts.on("-p", "--port PORT", Integer, "Server port") do |port|
              options[:port] = port
            end
            opts.on("-u", "--user USER", "Username") do |user|
              options[:user] = user
            end
            opts.on("-w", "--password", "Prompt for password") do
              options[:password] = true
            end
            opts.on("--csv", "Output in CSV format") do
              options[:csv] = true
            end
            opts.on("--json", "Output in JSON format") do
              options[:json] = true
            end
            opts.on("--table", "Output in table format") do
              options[:table] = true
            end
            opts.on("-h", "--help", "Show help") do
              @output.puts opts
              exit(0)
            end
          end

          parser.parse!(args)

          # Load history
          load_history

          # Connect to database
          connect_to_database(options)

          @output.puts "RubyDB Shell v#{RubyDB::VERSION}", :bold
          @output.puts "Connected to: #{@current_database || 'rubydb'}"
          @output.puts "Type '.help' for help, '.exit' to quit"
          @output.puts

          @connected = true

          while @connected
            begin
              prompt = @current_database ? "#{@current_database}> " : "rubydb> "
              input = Readline.readline(prompt, true)
              break if input.nil?

              input = input.strip
              next if input.empty?

              # Handle special commands
              case input
              when ".exit", ".quit"
                break
              when ".help", ".?"
                print_help
              when ".status"
                print_status
              when ".clear", ".cls"
                system("clear") || system("cls")
              when /\A\.db\s+(.+)/
                switch_database($1)
              when /\A\.(?:table|t)\s+(.+)/
                describe_table($1)
              when /\A\.tables/
                list_tables
              when /\A\.(?:schema|s)\s+(.+)/
                show_schema($1)
              when /\A\.(?:begin|txn|start)/
                begin_transaction
              when /\A\.commit/
                commit_transaction
              when /\A\.rollback/
                rollback_transaction
              when /\A\.explain\s+(.+)/
                explain_query($1)
              else
                execute_query(input)
              end
            rescue Interrupt
              @output.puts
              @output.info("Type .exit to quit")
            rescue => e
              @output.error(e.message)
              @output.debug(e.backtrace.join("\n")) if ENV["RUBYDB_DEBUG"]
            end
          end

          # Cleanup
          disconnect
          save_history
          @output.puts "Goodbye!"

          0
        end

        private

        def connect_to_database(options)
          config = RubyDB::Configuration::Config.instance
          
          db_name = options[:database] || config.get("database.name") || "rubydb"
          db_path = config.get("storage.data_dir") || "data"
          db_file = File.join(db_path, "#{db_name}.rdb")

          @engine = RubyDB::Storage::Engine.new(db_file, {})
          @current_database = db_name
          @connected = true
        rescue => e
          @output.error("Failed to connect: #{e.message}")
          exit(1)
        end

        def disconnect
          @engine.close if @engine
          @connected = false
        end

        def execute_query(sql)
          @output.spinner("Executing query...") do
            # Parse SQL
            parser = RubyDB::SQL::Parser.new(RubyDB::SQL::Lexer.new(sql).tokenize)
            statements = parser.parse

            statements.each do |stmt|
              result = execute_statement(stmt)
              display_result(result)
            end
          end
        rescue => e
          @output.error(e.message)
        end

        def execute_statement(statement)
          # Plan and execute the statement
          planner = RubyDB::Execution::Planner.new(@engine)
          plan = planner.plan(statement)
          
          executor = RubyDB::Execution::Executor.new(@engine)
          executor.execute(plan)
        end

        def display_result(result)
          rows = result[:rows] || []
          columns = result[:column_names] || []

          if rows.empty?
            @output.puts("0 rows returned", :gray)
            return
          end

          if @options[:json]
            @output.json(rows)
          elsif @options[:csv]
            # Output CSV
            @output.puts columns.join(",")
            rows.each { |row| @output.puts columns.map { |c| row[c].to_s }.join(",") }
          elsif @options[:table] != false
            # Table format
            table_rows = rows.map { |row| columns.map { |c| row[c].to_s } }
            @output.table(columns, table_rows, show_count: true)
          else
            # Default format
            rows.each do |row|
              @output.puts row.inspect
            end
            @output.puts "(#{rows.size} rows)", :gray
          end
        end

        def switch_database(name)
          db_path = File.join("data", "#{name}.rdb")
          if File.exist?(db_path)
            @engine.close if @engine
            @engine = RubyDB::Storage::Engine.new(db_path, {})
            @current_database = name
            @output.success("Switched to database: #{name}")
          else
            @output.error("Database '#{name}' does not exist")
          end
        end

        def list_tables
          tables = @engine.list_tables
          if tables.empty?
            @output.puts("No tables found", :gray)
          else
            @output.puts("Tables in #{@current_database}:", :bold)
            tables.each { |t| @output.puts("  - #{t}") }
            @output.puts("Total: #{tables.size}", :gray)
          end
        end

        def describe_table(name)
          columns = @engine.table_columns(name)
          if columns.empty?
            @output.error("Table '#{name}' not found")
            return
          end

          @output.puts("Table: #{name}", :bold)
          @output.puts("-" * 40)
          columns.each do |col|
            pk = col.primary_key? ? " PK" : ""
            null = col.nullable? ? "" : " NOT NULL"
            default = col.has_default? ? " DEFAULT #{col.default}" : ""
            @output.puts("  #{col.name}: #{col.type}#{pk}#{null}#{default}")
          end
          @output.puts("-" * 40)
          @output.puts("Total columns: #{columns.size}", :gray)
        end

        def show_schema(name)
          columns = @engine.table_columns(name)
          if columns.empty?
            @output.error("Table '#{name}' not found")
            return
          end

          sql = "CREATE TABLE #{name} (\n"
          cols = columns.map do |col|
            "  #{col.name} #{col.type}#{col.primary_key? ? " PRIMARY KEY" : ""}"
          end
          sql << cols.join(",\n")
          sql << "\n);"
          @output.puts(sql, :cyan)
        end

        def begin_transaction
          @transaction = @engine.begin_transaction
          @output.success("Transaction started")
        end

        def commit_transaction
          if @transaction
            @engine.commit_transaction(@transaction)
            @transaction = nil
            @output.success("Transaction committed")
          else
            @output.error("No active transaction")
          end
        end

        def rollback_transaction
          if @transaction
            @engine.rollback_transaction(@transaction)
            @transaction = nil
            @output.success("Transaction rolled back")
          else
            @output.error("No active transaction")
          end
        end

        def explain_query(sql)
          parser = RubyDB::SQL::Parser.new(RubyDB::SQL::Lexer.new(sql).tokenize)
          stmt = parser.parse.first
          planner = RubyDB::Execution::Planner.new(@engine)
          plan = planner.plan(stmt)

          @output.puts("EXPLAIN QUERY PLAN", :bold)
          @output.puts("-" * 40)
          @output.puts("  Scan Type: #{plan.scan_type}")
          @output.puts("  Table: #{plan.table_name}")
          @output.puts("  Estimated Cost: #{plan.estimated_cost}")
          @output.puts("  Estimated Rows: #{plan.estimated_rows}")
          @output.puts("  Predicate: #{plan.predicate.inspect}") if plan.predicate
          @output.puts("  Order By: #{plan.order_by.inspect}") if plan.order_by&.any?
          @output.puts("  Limit: #{plan.limit}") if plan.limit
          @output.puts("-" * 40)
        end

        def print_help
          @output.puts("\nAvailable Commands:", :bold)
          @output.puts("  .help, .?           Show this help")
          @output.puts("  .exit, .quit        Exit the shell")
          @output.puts("  .status             Show connection status")
          @output.puts("  .clear, .cls        Clear screen")
          @output.puts("  .db <name>          Switch database")
          @output.puts("  .tables             List all tables")
          @output.puts("  .table <name>       Describe a table")
          @output.puts("  .schema <name>      Show CREATE TABLE statement")
          @output.puts("  .begin, .txn        Begin transaction")
          @output.puts("  .commit             Commit transaction")
          @output.puts("  .rollback           Rollback transaction")
          @output.puts("  .explain <sql>      Explain query plan")
          @output.puts("\nAny other input is treated as SQL", :gray)
        end

        def print_status
          @output.puts("\nConnection Status:", :bold)
          @output.puts("  Connected: #{@connected}")
          @output.puts("  Database: #{@current_database}")
          @output.puts("  Version: #{RubyDB::VERSION}")
          @output.puts("  PID: #{Process.pid}")
          @output.puts("  In Transaction: #{!@transaction.nil?}")
          @output.puts("  Tables: #{@engine.list_tables.size}")
          @output.puts("  Storage: #{format_size(get_db_size)}")
        end

        def get_db_size
          db_path = File.join("data", "#{@current_database}.rdb")
          File.exist?(db_path) ? File.size(db_path) : 0
        end

        def format_size(bytes)
          return "0 B" if bytes == 0
          units = ["B", "KB", "MB", "GB", "TB"]
          exp = (Math.log(bytes) / Math.log(1024)).floor
          size = bytes / (1024.0 ** exp)
          "#{size.round(2)} #{units[exp]}"
        end

        def load_history
          return unless File.exist?(@history_file)
          File.readlines(@history_file).each { |line| Readline::HISTORY.push(line.chomp) }
        rescue
          # Ignore
        end

        def save_history
          history = Readline::HISTORY.to_a
          File.write(@history_file, history.join("\n"))
        rescue
          # Ignore
        end
      end
    end
  end
end