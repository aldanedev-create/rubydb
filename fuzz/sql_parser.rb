# frozen_string_literal: true

require "securerandom"

module RubyDB
  module Fuzz
    # SQLParserFuzzer - Fuzz testing for SQL parser
    class SQLParserFuzzer
      attr_reader :stats

      def initialize(config = {})
        @config = config
        @max_iterations = config[:max_iterations] || 10000
        @max_length = config[:max_length] || 1000
        @seed = config[:seed]
        @stats = {
          total_queries: 0,
          valid_queries: 0,
          invalid_queries: 0,
          errors: 0,
          crashes: 0,
          edge_cases_found: []
        }
        @lock = Mutex.new
        @generators = []
        @corpus = []

        # Seed random
        srand(@seed) if @seed

        register_generators
        load_corpus
      end

      def fuzz(iterations = @max_iterations)
        @lock.synchronize do
          iterations.times do |i|
            begin
              @stats[:total_queries] += 1

              # Generate random SQL
              sql = generate_sql

              # Parse the SQL
              result = parse_sql(sql)

              if result[:success]
                @stats[:valid_queries] += 1
                @corpus << sql if @corpus.size < 1000
              else
                @stats[:invalid_queries] += 1
                if result[:error] && result[:error].include?("crash")
                  @stats[:crashes] += 1
                  @stats[:edge_cases_found] << {
                    sql: sql,
                    error: result[:error],
                    iteration: i
                  }
                end
              end

            rescue => e
              @stats[:errors] += 1
              @stats[:crashes] += 1
              @stats[:edge_cases_found] << {
                sql: sql,
                error: e.message,
                backtrace: e.backtrace,
                iteration: i
              }
            end

            # Progress reporting
            if i % 100 == 0
              print_progress(i, iterations)
            end
          end

          @stats
        end
      end

      def generate_sql
        generator = @generators.sample
        generator.call
      end

      def parse_sql(sql)
        begin
          lexer = RubyDB::SQL::Lexer.new(sql)
          tokens = lexer.tokenize
          parser = RubyDB::SQL::Parser.new(tokens)
          ast = parser.parse

          { success: true, ast: ast, tokens: tokens }
        rescue RubyDB::ParserError => e
          { success: false, error: e.message, type: "parser_error" }
        rescue => e
          { success: false, error: "crash: #{e.message}", type: "crash" }
        end
      end

      def stats
        @lock.synchronize do
          @stats.merge({
            corpus_size: @corpus.size,
            success_rate: @stats[:total_queries] > 0 ? 
              (@stats[:valid_queries].to_f / @stats[:total_queries] * 100).round(2) : 0
          })
        end
      end

      private

      def register_generators
        # SELECT generators
        @generators << -> { generate_select }
        @generators << -> { generate_select_with_joins }
        @generators << -> { generate_select_with_where }
        @generators << -> { generate_select_with_group_by }
        @generators << -> { generate_select_with_order_by }
        @generators << -> { generate_select_with_subquery }

        # DML generators
        @generators << -> { generate_insert }
        @generators << -> { generate_update }
        @generators << -> { generate_delete }

        # DDL generators
        @generators << -> { generate_create_table }
        @generators << -> { generate_alter_table }
        @generators << -> { generate_drop_table }

        # Transaction generators
        @generators << -> { generate_begin }
        @generators << -> { generate_commit }
        @generators << -> { generate_rollback }

        # Complex generators
        @generators << -> { generate_complex_query }
        @generators << -> { generate_nested_queries }
        @generators << -> { generate_malformed_sql }
      end

      def generate_select
        tables = ["users", "orders", "products", "customers", "employees", "departments"]
        columns = ["id", "name", "email", "age", "created_at", "updated_at", "status", "price", "quantity"]

        table = tables.sample
        cols = columns.sample(rand(1..5)).join(", ")
        "SELECT #{cols} FROM #{table}"
      end

      def generate_select_with_where
        tables = ["users", "orders", "products", "customers"]
        columns = ["id", "name", "age", "email", "price", "status", "created_at"]
        operators = ["=", "!=", ">", "<", ">=", "<=", "LIKE", "IN", "BETWEEN"]

        table = tables.sample
        col = columns.sample
        op = operators.sample
        value = generate_value(col)

        "SELECT * FROM #{table} WHERE #{col} #{op} #{value}"
      end

      def generate_select_with_joins
        tables = ["users", "orders", "products", "customers"]
        join_types = ["INNER", "LEFT", "RIGHT", "FULL"]

        t1 = tables.sample
        t2 = (tables - [t1]).sample
        join_type = join_types.sample

        "SELECT * FROM #{t1} #{join_type} JOIN #{t2} ON #{t1}.id = #{t2}.#{t1}_id"
      end

      def generate_select_with_group_by
        tables = ["users", "orders", "products"]
        columns = ["id", "name", "category", "status", "department"]

        table = tables.sample
        col = columns.sample

        "SELECT #{col}, COUNT(*) FROM #{table} GROUP BY #{col}"
      end

      def generate_select_with_order_by
        tables = ["users", "orders", "products"]
        columns = ["id", "name", "created_at", "price", "age"]
        directions = ["ASC", "DESC"]

        table = tables.sample
        col = columns.sample
        dir = directions.sample

        "SELECT * FROM #{table} ORDER BY #{col} #{dir}"
      end

      def generate_select_with_subquery
        tables = ["users", "orders", "products"]
        sub_tables = ["users", "orders", "customers"]

        table = tables.sample
        sub_table = sub_tables.sample

        "SELECT * FROM #{table} WHERE id IN (SELECT id FROM #{sub_table} WHERE id > 10)"
      end

      def generate_insert
        tables = ["users", "orders", "products"]
        table = tables.sample

        case table
        when "users"
          "INSERT INTO users (name, age, email) VALUES ('user#{rand(1000)}', #{rand(18..65)}, 'user#{rand(1000)}@example.com')"
        when "orders"
          "INSERT INTO orders (user_id, product_id, quantity) VALUES (#{rand(1..100)}, #{rand(1..50)}, #{rand(1..10)})"
        else
          "INSERT INTO products (name, price, category) VALUES ('product#{rand(1000)}', #{rand(10..1000)}.99, 'category#{rand(1..5)}')"
        end
      end

      def generate_update
        tables = ["users", "orders", "products"]
        table = tables.sample

        case table
        when "users"
          "UPDATE users SET age = #{rand(18..65)} WHERE id = #{rand(1..100)}"
        when "orders"
          "UPDATE orders SET quantity = #{rand(1..10)} WHERE id = #{rand(1..100)}"
        else
          "UPDATE products SET price = #{rand(10..1000)}.99 WHERE id = #{rand(1..50)}"
        end
      end

      def generate_delete
        tables = ["users", "orders", "products"]
        table = tables.sample

        "DELETE FROM #{table} WHERE id = #{rand(1..100)}"
      end

      def generate_create_table
        tables = ["temp_users", "temp_orders", "temp_products"]
        columns = [
          ["id INTEGER PRIMARY KEY", "name TEXT", "age INTEGER"],
          ["id INTEGER PRIMARY KEY", "user_id INTEGER", "product_id INTEGER", "quantity INTEGER"],
          ["id INTEGER PRIMARY KEY", "name TEXT", "price DECIMAL", "category TEXT"]
        ]

        table = tables.sample
        cols = columns.sample

        "CREATE TABLE #{table} (#{cols.join(', ')})"
      end

      def generate_alter_table
        tables = ["temp_users", "temp_orders", "temp_products"]
        operations = [
          "ADD COLUMN new_column TEXT",
          "DROP COLUMN old_column",
          "RENAME COLUMN old_column TO new_column"
        ]

        table = tables.sample
        op = operations.sample

        "ALTER TABLE #{table} #{op}"
      end

      def generate_drop_table
        tables = ["temp_users", "temp_orders", "temp_products"]
        table = tables.sample

        "DROP TABLE #{table}"
      end

      def generate_begin
        ["BEGIN", "BEGIN TRANSACTION", "START TRANSACTION"].sample
      end

      def generate_commit
        ["COMMIT", "COMMIT TRANSACTION", "END TRANSACTION"].sample
      end

      def generate_rollback
        ["ROLLBACK", "ROLLBACK TRANSACTION"].sample
      end

      def generate_complex_query
        queries = [
          "SELECT * FROM users WHERE id IN (SELECT user_id FROM orders WHERE quantity > 5) AND age > 18",
          "SELECT u.name, o.id FROM users u JOIN orders o ON u.id = o.user_id WHERE o.created_at > '2024-01-01'",
          "SELECT category, AVG(price) FROM products GROUP BY category HAVING AVG(price) > 100",
          "SELECT * FROM users WHERE name LIKE 'A%' OR age BETWEEN 25 AND 35 ORDER BY age DESC"
        ]

        queries.sample
      end

      def generate_nested_queries
        depth = rand(1..3)
        sql = "SELECT * FROM users"
        depth.times do
          sql = "SELECT * FROM (#{sql}) AS sub"
        end
        sql << " WHERE id > 0"
      end

      def generate_malformed_sql
        malformed = [
          "SELECT FROM users",
          "SELECT * users",
          "SELECT * FROM",
          "INSERT INTO users VALUES",
          "UPDATE users SET",
          "DELETE FROM",
          "SELECT * FROM users WHERE id = '",
          "SELECT * FROM users WHERE id = 1 AND",
          "CREATE TABLE (",
          "ALTER TABLE ADD",
          "BEGIN TRANSACT",
          "COMMIT TRANSACT",
          "ROLLBACK TRANSACT"
        ]

        malformed.sample
      end

      def generate_value(column)
        case column
        when "id"
          rand(1..1000).to_s
        when "name", "email"
          "'#{SecureRandom.hex(8)}'"
        when "age"
          rand(18..65).to_s
        when "price"
          "#{rand(10..1000)}.99"
        when "created_at", "updated_at"
          "'2024-01-01'"
        when "status"
          "'active'"
        else
          rand(1..100).to_s
        end
      end

      def load_corpus
        # Load common SQL patterns
        @corpus = [
          "SELECT * FROM users",
          "SELECT id, name FROM users",
          "SELECT COUNT(*) FROM users",
          "SELECT * FROM users WHERE id = 1",
          "SELECT * FROM users ORDER BY name",
          "INSERT INTO users (name, age) VALUES ('John', 30)",
          "UPDATE users SET age = 31 WHERE id = 1",
          "DELETE FROM users WHERE id = 1",
          "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)",
          "DROP TABLE users",
          "BEGIN TRANSACTION",
          "COMMIT",
          "ROLLBACK"
        ]
      end

      def print_progress(current, total)
        percent = (current.to_f / total * 100).round(1)
        bar_length = 40
        filled = (percent / 100 * bar_length).round
        bar = "[" + "=" * filled + " " * (bar_length - filled) + "]"

        print("\rSQL Parser Fuzzing: #{bar} #{percent}% (#{current}/#{total})", nil, false)
        print("\n") if current == total - 1
      end
    end
  end
end