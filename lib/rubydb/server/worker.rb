# frozen_string_literal: true

module RubyDB
  module Server
    # Worker - Processes requests from clients
    class Worker
      attr_reader :id, :stats

      def initialize(id, config, engine, transaction_manager)
        @id = id
        @config = config
        @engine = engine
        @transaction_manager = transaction_manager
        @queue = Queue.new
        @running = false
        @thread = nil
        @stats = {
          requests_processed: 0,
          requests_failed: 0,
          total_processing_time_ms: 0,
          avg_processing_time_ms: 0,
          last_request_time: nil,
          idle_time: 0
        }
        @lock = Mutex.new
        @last_activity = Time.now
      end

      def start
        @lock.synchronize do
          return if @running

          @running = true
          @thread = Thread.new { work_loop }
          true
        end
      end

      def stop
        @lock.synchronize do
          return unless @running

          @running = false
          @queue << nil

          if @thread
            @thread.join(5)
            @thread.kill if @thread.alive?
            @thread = nil
          end

          true
        end
      end

      def submit(request)
        @queue << request
        true
      end

      def busy?
        !@queue.empty?
      end

      def running?
        @running
      end

      def stats
        @lock.synchronize do
          @stats.merge({
            id: @id,
            running: @running,
            queue_size: @queue.size,
            busy: busy?,
            idle_time: (Time.now - @last_activity).round(2)
          })
        end
      end

      private

      def work_loop
        while @running
          begin
            request = @queue.pop
            break if request.nil?

            process_request(request)

          rescue => e
            @stats[:requests_failed] += 1
          end
        end
      end

      def process_request(request)
        start_time = Time.now

        begin
          # Process the request using the engine and transaction manager
          result = handle_request(request)

          # Send response back through connection
          if request[:connection]
            request[:connection].send_response(result)
          end

          @stats[:requests_processed] += 1
          @last_activity = Time.now

        rescue => e
          @stats[:requests_failed] += 1
          raise
        ensure
          elapsed_ms = (Time.now - start_time) * 1000
          @stats[:total_processing_time_ms] += elapsed_ms
          @stats[:avg_processing_time_ms] = @stats[:total_processing_time_ms] / @stats[:requests_processed] if @stats[:requests_processed] > 0
          @stats[:last_request_time] = Time.now
        end
      end

      def handle_request(request)
        type = request[:type]
        connection = request[:connection]

        case type
        when :query
          handle_query(request, connection)
        when :prepare
          handle_prepare(request, connection)
        when :execute
          handle_execute(request, connection)
        when :begin
          handle_begin(request, connection)
        when :commit
          handle_commit(request, connection)
        when :rollback
          handle_rollback(request, connection)
        when :ping
          handle_ping(request, connection)
        else
          error_response("Unknown request type: #{type}")
        end
      end

      def handle_query(request, connection)
        sql = request[:sql]
        params = request[:params] || []

        # Execute query using engine
        result = @engine.execute(sql, params)

        success_response(result)
      end

      def handle_prepare(request, connection)
        sql = request[:sql]
        stmt_id = "stmt_#{Time.now.to_i}_#{@id}"

        success_response({ statement_id: stmt_id, sql: sql })
      end

      def handle_execute(request, connection)
        stmt_id = request[:statement_id]
        params = request[:params] || []

        # Execute prepared statement
        result = @engine.execute_prepared(stmt_id, params)

        success_response(result)
      end

      def handle_begin(request, connection)
        @transaction_manager.begin_transaction
        success_response({ transaction_id: @transaction_manager.current_transaction&.id })
      end

      def handle_commit(request, connection)
        @transaction_manager.commit_transaction
        success_response({ committed: true })
      end

      def handle_rollback(request, connection)
        @transaction_manager.rollback_transaction
        success_response({ rolled_back: true })
      end

      def handle_ping(request, connection)
        success_response({ pong: true })
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