# frozen_string_literal: true

module RubyDB
  module Fuzz
    # QueryEngineFuzzer - Fuzz testing for query execution engine
    class QueryEngineFuzzer
      attr_reader :stats

      def initialize(engine, config = {})
        @engine = engine
        @config = config
        @max_iterations = config[:max_iterations] || 10000
        @seed = config[:seed]
        @stats = {
          total_queries: 0,
          successful_queries: 0,
          failed_queries: 0,
          errors: 0,
          crashes: 0,
          edge_cases_found: [],
          query_times: [],
          avg_query_time: 0
        }
        @lock = Mutex.new
        @parser_fuzzer = SQLParserFuzzer.new(config)
        @corpus = []

        srand(@seed) if @seed
      end

      def fuzz(iterations = @max_iterations)
        @lock.synchronize do
          # Ensure test tables exist
          setup_test_tables

          iterations.times do |i|
            begin
              @stats[:total_queries] += 1
              start_time = Time.now

              # Generate or get SQL
              sql = if rand < 0.3 && @corpus.any?
                @corpus.sample
              else
                @parser_fuzzer.generate_sql
              end

              # Execute query
              result = execute_query(sql)

              elapsed_ms = (Time.now - start_time) * 1000
              @stats[:query_times] << elapsed_ms

              if result[:success]
                @stats[:successful_queries] += 1
                @corpus << sql if @corpus.size < 1000 && !@corpus.include?(sql)
              else
                @stats[:failed_queries] += 1
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

          # Update average query time
          if @stats[:query_times].any?
            @stats[:avg_query_time] = @stats[:query_times].sum / @stats[:query_times].size
          end

          # Cleanup
          cleanup_test_tables

          @stats
        end
      end

      def execute_query(sql)
        begin
          # Parse SQL
          lexer = RubyDB::SQL::Lexer.new(sql)
          tokens = lexer.tokenize
          parser = RubyDB::SQL::Parser.new(tokens)
          statements = parser.parse

          # Execute each statement
          results = []
          statements.each do |stmt|
            # Plan and execute
            planner = RubyDB::Execution::Planner.new(@engine)
            plan = planner.plan(stmt)
            executor = RubyDB::Execution::Executor.new(@engine)
            result = executor.execute(plan)
            results << result
          end

          { success: true, results: results }
        rescue RubyDB::ParserError, RubyDB::ExecutionError => e
          { success: false, error: e.message, type: "execution_error" }
        rescue => e
          { success: false, error: "crash: #{e.message}", type: "crash" }
        end
      end

      def stats
        @lock.synchronize do
          @stats.merge({
            corpus_size: @corpus.size,
            success_rate: @stats[:total_queries] > 0 ?
              (@stats[:successful_queries].to_f / @stats[:total_queries] * 100).round(2) : 0,
            min_query_time: @stats[:query_times].min || 0,
            max_query_time: @stats[:query_times].max || 0,
            median_query_time: @stats[:query_times].sort[@stats[:query_times].size / 2] || 0
          })
        end
      end

      private

      def setup_test_tables
        # Create test tables for fuzzing
        begin
          @engine.execute("CREATE TABLE fuzz_users (id INTEGER PRIMARY KEY, name TEXT, age INTEGER, email TEXT)")
          @engine.execute("CREATE TABLE fuzz_orders (id INTEGER PRIMARY KEY, user_id INTEGER, product_id INTEGER, quantity INTEGER, price DECIMAL)")
          @engine.execute("CREATE TABLE fuzz_products (id INTEGER PRIMARY KEY, name TEXT, price DECIMAL, category TEXT)")

          # Insert test data
          50.times do |i|
            @engine.execute("INSERT INTO fuzz_users (name, age, email) VALUES ('user#{i}', #{rand(18..65)}, 'user#{i}@example.com')")
          end

          50.times do |i|
            @engine.execute("INSERT INTO fuzz_orders (user_id, product_id, quantity, price) VALUES (#{rand(1..50)}, #{rand(1..30)}, #{rand(1..10)}, #{rand(10..1000)})")
          end

          30.times do |i|
            @engine.execute("INSERT INTO fuzz_products (name, price, category) VALUES ('product#{i}', #{rand(10..1000)}.99, 'category#{rand(1..5)}')")
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

      def print_progress(current, total)
        percent = (current.to_f / total * 100).round(1)
        bar_length = 40
        filled = (percent / 100 * bar_length).round
        bar = "[" + "=" * filled + " " * (bar_length - filled) + "]"

        print("\rQuery Engine Fuzzing: #{bar} #{percent}% (#{current}/#{total})", nil, false)
        print("\n") if current == total - 1
      end
    end
  end
end