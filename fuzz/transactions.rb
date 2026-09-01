# frozen_string_literal: true

module RubyDB
  module Fuzz
    # TransactionsFuzzer - Fuzz testing for transaction system
    class TransactionsFuzzer
      attr_reader :stats

      def initialize(engine, config = {})
        @engine = engine
        @config = config
        @max_iterations = config[:max_iterations] || 5000
        @seed = config[:seed]
        @stats = {
          total_transactions: 0,
          successful_transactions: 0,
          failed_transactions: 0,
          committed_transactions: 0,
          rolled_back_transactions: 0,
          deadlocks_detected: 0,
          errors: 0,
          crashes: 0,
          edge_cases_found: [],
          avg_transaction_time: 0,
          total_transaction_time: 0
        }
        @lock = Mutex.new
        @transaction_manager = nil
        @active_transactions = []

        srand(@seed) if @seed
      end

      def fuzz(iterations = @max_iterations)
        @lock.synchronize do
          @transaction_manager = RubyDB::Transactions::TransactionManager.new(@engine, @config)

          # Setup test tables
          setup_test_tables

          iterations.times do |i|
            begin
              @stats[:total_transactions] += 1
              start_time = Time.now

              # Begin transaction
              result = execute_transaction

              elapsed_ms = (Time.now - start_time) * 1000
              @stats[:total_transaction_time] += elapsed_ms

              if result[:success]
                @stats[:successful_transactions] += 1
                if result[:committed]
                  @stats[:committed_transactions] += 1
                elsif result[:rolled_back]
                  @stats[:rolled_back_transactions] += 1
                end
              else
                @stats[:failed_transactions] += 1
                if result[:error] && result[:error].include?("deadlock")
                  @stats[:deadlocks_detected] += 1
                end
                if result[:error] && result[:error].include?("crash")
                  @stats[:crashes] += 1
                  @stats[:edge_cases_found] << {
                    iteration: i,
                    error: result[:error]
                  }
                end
              end

            rescue => e
              @stats[:errors] += 1
              @stats[:crashes] += 1
              @stats[:edge_cases_found] << {
                iteration: i,
                error: e.message,
                backtrace: e.backtrace
              }
            end

            # Progress reporting
            if i % 100 == 0
              print_progress(i, iterations)
            end
          end

          # Cleanup
          cleanup_test_tables

          # Update stats
          if @stats[:total_transactions] > 0
            @stats[:avg_transaction_time] = @stats[:total_transaction_time] / @stats[:total_transactions]
          end

          @stats
        end
      end

      def execute_transaction
        # Random transaction type
        transaction_type = rand(0..4)

        case transaction_type
        when 0
          execute_simple_transaction
        when 1
          execute_multi_statement_transaction
        when 2
          execute_transaction_with_savepoints
        when 3
          execute_conflicting_transaction
        else
          execute_nested_transaction
        end
      end

      def execute_simple_transaction
        isolation_level = [:read_uncommitted, :read_committed, :repeatable_read, :serializable].sample

        begin
          tx = @transaction_manager.begin_transaction(isolation_level: isolation_level)

          # Perform random operations
          operations = rand(1..5)
          operations.times do
            op = [:insert, :update, :delete].sample
            table = ["fuzz_users", "fuzz_orders", "fuzz_products"].sample

            case op
            when :insert
              @engine.insert_row(table, get_table_columns(table), generate_record_values(table))
            when :update
              @engine.update_row(table, rand(1..50), generate_record_values(table))
            when :delete
              @engine.delete_row(table, rand(1..50))
            end
          end

          # Random commit or rollback
          if rand < 0.7
            @transaction_manager.commit_transaction(tx)
            { success: true, committed: true }
          else
            @transaction_manager.rollback_transaction(tx)
            { success: true, rolled_back: true }
          end

        rescue => e
          { success: false, error: e.message }
        end
      end

      def execute_multi_statement_transaction
        begin
          tx = @transaction_manager.begin_transaction

          3.times do
            # Mix of operations on different tables
            statements = [
              "INSERT INTO fuzz_users (name, age, email) VALUES ('fuzz_#{rand(1000)}', #{rand(18..65)}, 'fuzz@test.com')",
              "UPDATE fuzz_orders SET quantity = #{rand(1..20)} WHERE id = #{rand(1..50)}",
              "DELETE FROM fuzz_products WHERE id = #{rand(1..30)}",
              "SELECT * FROM fuzz_users WHERE age > #{rand(18..65)}"
            ]

            sql = statements.sample
            @engine.execute(sql)
          end

          @transaction_manager.commit_transaction(tx)
          { success: true, committed: true }

        rescue => e
          { success: false, error: e.message }
        end
      end

      def execute_transaction_with_savepoints
        begin
          tx = @transaction_manager.begin_transaction

          # First operation
          @engine.insert_row("fuzz_users", get_table_columns("fuzz_users"), 
            { "name" => "savepoint_test", "age" => 25, "email" => "savepoint@test.com" })

          # Create savepoint
          savepoint = tx.create_savepoint("before_update")

          # Update operation
          @engine.update_row("fuzz_users", 1, { "age" => 30 })

          # Rollback to savepoint
          tx.rollback_to_savepoint("before_update")

          # Commit
          @transaction_manager.commit_transaction(tx)
          { success: true, committed: true }

        rescue => e
          { success: false, error: e.message }
        end
      end

      def execute_conflicting_transaction
        begin
          # Create two transactions that could conflict
          tx1 = @transaction_manager.begin_transaction
          tx2 = @transaction_manager.begin_transaction

          # Update same row from both transactions
          @engine.update_row("fuzz_users", 1, { "name" => "tx1_update" })
          @engine.update_row("fuzz_users", 1, { "name" => "tx2_update" })

          # Commit both (one will fail due to conflict)
          begin
            @transaction_manager.commit_transaction(tx1)
          rescue => e
            # Expected conflict
          end

          begin
            @transaction_manager.commit_transaction(tx2)
          rescue => e
            # Expected conflict
          end

          { success: true, committed: true }

        rescue => e
          { success: false, error: "deadlock: #{e.message}" }
        end
      end

      def execute_nested_transaction
        begin
          tx = @transaction_manager.begin_transaction

          @engine.insert_row("fuzz_users", get_table_columns("fuzz_users"),
            { "name" => "nested_test", "age" => 25, "email" => "nested@test.com" })

          # Nested transaction
          nested_tx = @transaction_manager.begin_transaction(parent: tx)
          @engine.update_row("fuzz_users", 1, { "age" => 35 })

          if rand < 0.5
            @transaction_manager.commit_transaction(nested_tx)
          else
            @transaction_manager.rollback_transaction(nested_tx)
          end

          @transaction_manager.commit_transaction(tx)
          { success: true, committed: true }

        rescue => e
          { success: false, error: e.message }
        end
      end

      def setup_test_tables
        begin
          @engine.execute("CREATE TABLE fuzz_users (id INTEGER PRIMARY KEY, name TEXT, age INTEGER, email TEXT)")
          @engine.execute("CREATE TABLE fuzz_orders (id INTEGER PRIMARY KEY, user_id INTEGER, product_id INTEGER, quantity INTEGER, price DECIMAL)")
          @engine.execute("CREATE TABLE fuzz_products (id INTEGER PRIMARY KEY, name TEXT, price DECIMAL, category TEXT)")

          # Insert test data
          50.times do |i|
            @engine.execute("INSERT INTO fuzz_users (name, age, email) VALUES ('user#{i}', #{rand(18..65)}, 'user#{i}@test.com')")
          end

          50.times do |i|
            @engine.execute("INSERT INTO fuzz_orders (user_id, product_id, quantity, price) VALUES (#{rand(1..50)}, #{rand(1..30)}, #{rand(1..10)}, #{rand(10..1000)})")
          end

          30.times do |i|
            @engine.execute("INSERT INTO fuzz_products (name, price, category) VALUES ('product#{i}', #{rand(10..1000)}.99, 'cat#{rand(1..5)}')")
          end
        rescue => e
          # Tables might already exist
        end
      end

      def cleanup_test_tables
        begin
          @engine.execute("DROP TABLE fuzz_users")
          @engine.execute("DROP TABLE fuzz_orders")
          @engine.execute("DROP TABLE fuzz_products")
        rescue => e
          # Ignore cleanup errors
        end
      end

      def get_table_columns(table)
        case table
        when "fuzz_users"
          [RubyDB::Catalog::Column.new("id", :integer, primary_key: true),
           RubyDB::Catalog::Column.new("name", :text),
           RubyDB::Catalog::Column.new("age", :integer),
           RubyDB::Catalog::Column.new("email", :text)]
        when "fuzz_orders"
          [RubyDB::Catalog::Column.new("id", :integer, primary_key: true),
           RubyDB::Catalog::Column.new("user_id", :integer),
           RubyDB::Catalog::Column.new("product_id", :integer),
           RubyDB::Catalog::Column.new("quantity", :integer),
           RubyDB::Catalog::Column.new("price", :decimal)]
        when "fuzz_products"
          [RubyDB::Catalog::Column.new("id", :integer, primary_key: true),
           RubyDB::Catalog::Column.new("name", :text),
           RubyDB::Catalog::Column.new("price", :decimal),
           RubyDB::Catalog::Column.new("category", :text)]
        else
          []
        end
      end

      def generate_record_values(table)
        case table
        when "fuzz_users"
          { "name" => "user_#{rand(1000)}", "age" => rand(18..65), "email" => "user#{rand(1000)}@test.com" }
        when "fuzz_orders"
          { "user_id" => rand(1..100), "product_id" => rand(1..50), "quantity" => rand(1..10), "price" => rand(10..1000) }
        when "fuzz_products"
          { "name" => "product_#{rand(1000)}", "price" => rand(10..1000), "category" => "cat_#{rand(1..5)}" }
        else
          {}
        end
      end

      def stats
        @lock.synchronize do
          @stats.merge({
            success_rate: @stats[:total_transactions] > 0 ?
              (@stats[:successful_transactions].to_f / @stats[:total_transactions] * 100).round(2) : 0,
            commit_rate: @stats[:total_transactions] > 0 ?
              (@stats[:committed_transactions].to_f / @stats[:total_transactions] * 100).round(2) : 0
          })
        end
      end

      def print_progress(current, total)
        percent = (current.to_f / total * 100).round(1)
        bar_length = 40
        filled = (percent / 100 * bar_length).round
        bar = "[" + "=" * filled + " " * (bar_length - filled) + "]"

        print("\rTransactions Fuzzing: #{bar} #{percent}% (#{current}/#{total})", nil, false)
        print("\n") if current == total - 1
      end
    end
  end
end