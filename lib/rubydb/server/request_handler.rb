# frozen_string_literal: true

require "monitor"

module RubyDB
  module Server
    # RequestHandler - Handles and routes requests
    class RequestHandler
      attr_reader :stats

      def initialize(engine, transaction_manager, config = {})
        @engine = engine
        @transaction_manager = transaction_manager
        @config = config
        @stats = {
          requests_processed: 0,
          requests_failed: 0,
          query_requests: 0,
          prepare_requests: 0,
          execute_requests: 0,
          transaction_requests: 0,
          other_requests: 0,
          total_processing_time_ms: 0,
          avg_processing_time_ms: 0
        }
        @lock = Monitor.new
        @handlers = {}
        @middleware = []
        @query_handlers = {}
        @prepared_statements = {}
        @statement_counter = 0
        @health = config[:health] || RubyDB::Monitoring::Health.new(engine, auto_check: false)
        @metrics = config[:metrics] || RubyDB::Monitoring::Metrics.new(auto_flush: false)

        # Register default handlers
        register_default_handlers
      end

      def handle(request)
        @lock.synchronize do
          start_time = Time.now

          begin
            # Apply middleware
            request = apply_middleware(request)

            # Route request
            result = route_request(request)

            @stats[:requests_processed] += 1

            elapsed_ms = (Time.now - start_time) * 1000
            @stats[:total_processing_time_ms] += elapsed_ms
            @stats[:avg_processing_time_ms] = @stats[:total_processing_time_ms] / @stats[:requests_processed] if @stats[:requests_processed] > 0

            result

          rescue => e
            @stats[:requests_failed] += 1
            error_response(e.message)
          end
        end
      end

      def register_handler(type, handler = nil, &block)
        @handlers[type] = handler || block
      end

      def register_middleware(middleware)
        @middleware << middleware
      end

      def register_query_handler(pattern, handler)
        @query_handlers[pattern] = handler
      end

      def prepare_statement(sql)
        @lock.synchronize do
          stmt_id = "stmt_#{Time.now.to_i}_#{@statement_counter}"
          @statement_counter += 1

          @prepared_statements[stmt_id] = {
            sql: sql,
            created_at: Time.now,
            params: extract_params(sql)
          }

          stmt_id
        end
      end

      def execute_statement(stmt_id, params = [])
        @lock.synchronize do
          stmt = @prepared_statements[stmt_id]
          return error_response("Statement not found") unless stmt

          # Execute the prepared statement
          execute_sql(stmt[:sql], params)
        end
      end

      def close_statement(stmt_id)
        @lock.synchronize do
          @prepared_statements.delete(stmt_id)
          success_response({ closed: true })
        end
      end

      def stats
        @lock.synchronize do
          @stats.merge({
            prepared_statements: @prepared_statements.size,
            middleware_count: @middleware.size,
            handler_count: @handlers.size
          })
        end
      end

      private

      def register_default_handlers
        # Query handler
        register_handler(:query) do |request|
          handle_query(request)
        end

        # Prepare handler
        register_handler(:prepare) do |request|
          handle_prepare(request)
        end

        # Execute handler
        register_handler(:execute) do |request|
          handle_execute(request)
        end

        # Transaction handlers
        register_handler(:begin) do |request|
          handle_begin(request)
        end

        register_handler(:commit) do |request|
          handle_commit(request)
        end

        register_handler(:rollback) do |request|
          handle_rollback(request)
        end

        # Ping handler
        register_handler(:ping) do |request|
          handle_ping(request)
        end

        register_handler(:liveness) { |_request| success_response(@health.liveness) }
        register_handler(:readiness) { |_request| success_response(@health.readiness) }
        register_handler(:health) { |_request| success_response(@health.check) }
        register_handler(:metrics) { |_request| success_response({ format: "prometheus", body: @metrics.to_prometheus }) }
      end

      def route_request(request)
        type = request[:type]

        handler = @handlers[type]
        if handler
          handler.call(request)
        else
          error_response("No handler for request type: #{type}")
        end
      end

      def apply_middleware(request)
        @middleware.each do |mw|
          request = mw.call(request)
          break if request.nil?
        end
        request
      end

      def handle_query(request)
        @stats[:query_requests] += 1
        sql = request[:sql]
        params = request[:params] || []

        # Check for prepared statement pattern
        @query_handlers.each do |pattern, handler|
          if sql.match?(pattern)
            return handler.call(sql, params)
          end
        end

        # Execute SQL
        execute_sql(sql, params)
      end

      def handle_prepare(request)
        @stats[:prepare_requests] += 1
        sql = request[:sql]
        stmt_id = prepare_statement(sql)

        success_response({
          statement_id: stmt_id,
          sql: sql,
          params: @prepared_statements[stmt_id][:params]
        })
      end

      def handle_execute(request)
        @stats[:execute_requests] += 1
        stmt_id = request[:statement_id]
        params = request[:params] || []

        execute_statement(stmt_id, params)
      end

      def handle_begin(request)
        @stats[:transaction_requests] += 1
        @transaction_manager.begin_transaction

        success_response({
          transaction_id: @transaction_manager.current_transaction&.id
        })
      end

      def handle_commit(request)
        @stats[:transaction_requests] += 1
        @transaction_manager.commit_transaction

        success_response({ committed: true })
      end

      def handle_rollback(request)
        @stats[:transaction_requests] += 1
        @transaction_manager.rollback_transaction

        success_response({ rolled_back: true })
      end

      def handle_ping(request)
        @stats[:other_requests] += 1
        success_response({ pong: true, timestamp: Time.now.iso8601 })
      end

      def execute_sql(sql, params)
        tokens = RubyDB::SQL::Lexer.new(sql).tokenize
        statements = RubyDB::SQL::Parser.new(tokens).parse
        results = statements.map do |statement|
          plan = RubyDB::Execution::Planner.new(@engine).plan(statement)
          RubyDB::Execution::Executor.new(@engine).execute(plan)
        end
        results.size == 1 ? results.first : results
      end

      def extract_params(sql)
        # Extract parameter placeholders from SQL
        sql.scan(/\$(\d+)/).flatten.map(&:to_i).uniq.sort
      end

      def success_response(data)
        {
          success: true,
          data: data,
          timestamp: Time.now.iso8601
        }
      end

      def error_response(message)
        {
          success: false,
          error: message,
          timestamp: Time.now.iso8601
        }
      end
    end
  end
end
