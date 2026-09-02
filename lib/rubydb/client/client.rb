# frozen_string_literal: true

require "socket"
require "json"
require "time"
require "digest"

require_relative "connection"
require_relative "result"
require_relative "statement"
require_relative "prepared_statement"
require_relative "transaction"
require_relative "connection_pool"
require_relative "../protocol/protocol"
require_relative "../protocol/message"

module RubyDB
  module Client
    # Client - Main database client
    class Client
      attr_reader :config, :connection, :pool, :stats

      def initialize(config = {})
        @config = {
          host: config[:host] || "localhost",
          port: config[:port] || 7432,
          username: config[:username] || "rubydb",
          password: config[:password] || "",
          database: config[:database] || "rubydb",
          timeout: config[:timeout] || 30,
          pool_size: config[:pool_size] || 5,
          auto_connect: config.fetch(:auto_connect, true),
          ssl: config[:ssl] || false,
          compress: config[:compress] || false,
          format: config[:format] || :json
        }

        @stats = {
          queries_executed: 0,
          queries_failed: 0,
          transactions_started: 0,
          transactions_committed: 0,
          transactions_rolled_back: 0,
          prepared_statements: 0,
          bytes_sent: 0,
          bytes_received: 0,
          connection_time_ms: 0,
          total_query_time_ms: 0,
          avg_query_time_ms: 0
        }

        @lock = Mutex.new
        @connected = false
        @connection = nil
        @pool = nil
        @transaction = nil

        # Initialize connection pool if pool_size > 1
        if @config[:pool_size] > 1
          @pool = ConnectionPool.new(@config)
        end

        # Auto-connect if configured
        connect if @config[:auto_connect]
      end

      def connect
        @lock.synchronize do
          return if @connected

          start_time = Time.now

          begin
            if @pool
              @connection = @pool.get_connection
            else
              @connection = Connection.new(@config)
              @connection.connect
            end

            @connected = true
            @stats[:connection_time_ms] = (Time.now - start_time) * 1000

            true
          rescue => e
            raise ClientError, "Connection failed: #{e.message}"
          end
        end
      end

      def disconnect
        @lock.synchronize do
          return unless @connected

          if @pool
            @pool.release_connection(@connection)
          else
            @connection.disconnect
          end

          @connection = nil
          @connected = false
          @transaction = nil

          true
        end
      end

      def connected?
        @connected && @connection && @connection.connected?
      end

      def query(sql, params = [])
        @lock.synchronize do
          ensure_connected

          start_time = Time.now

          begin
            # Send query
            response = @connection.send_query(sql, params)
            @stats[:queries_executed] += 1

            # Parse result
            result = Result.new(response)

            elapsed_ms = (Time.now - start_time) * 1000
            @stats[:total_query_time_ms] += elapsed_ms
            @stats[:avg_query_time_ms] = @stats[:total_query_time_ms] / @stats[:queries_executed] if @stats[:queries_executed] > 0

            result

          rescue => e
            @stats[:queries_failed] += 1
            raise
          end
        end
      end

      def prepare(sql)
        @lock.synchronize do
          ensure_connected

          begin
            response = @connection.send_prepare(sql)
            @stats[:prepared_statements] += 1

            PreparedStatement.new(response[:statement_id], sql, self)
          rescue => e
            @stats[:queries_failed] += 1
            raise
          end
        end
      end

      def execute(statement_id, params = [])
        @lock.synchronize do
          ensure_connected

          start_time = Time.now

          begin
            response = @connection.send_execute(statement_id, params)
            @stats[:queries_executed] += 1

            result = Result.new(response)

            elapsed_ms = (Time.now - start_time) * 1000
            @stats[:total_query_time_ms] += elapsed_ms
            @stats[:avg_query_time_ms] = @stats[:total_query_time_ms] / @stats[:queries_executed] if @stats[:queries_executed] > 0

            result

          rescue => e
            @stats[:queries_failed] += 1
            raise
          end
        end
      end

      def close_statement(statement_id)
        @lock.synchronize do
          ensure_connected
          @connection.send_close(statement_id)
        end
      end

      def begin_transaction(options = {})
        @lock.synchronize do
          ensure_connected

          if @transaction && @transaction.active?
            raise ClientError, "Transaction already active"
          end

          @connection.send_begin(options)
          @transaction = Transaction.new(self, options)
          @stats[:transactions_started] += 1

          @transaction
        end
      end

      def commit
        @lock.synchronize do
          ensure_connected

          unless @transaction && @transaction.active?
            raise ClientError, "No active transaction"
          end

          @connection.send_commit
          @transaction.mark_committed
          @stats[:transactions_committed] += 1

          @transaction = nil
        end
      end

      def rollback
        @lock.synchronize do
          ensure_connected

          unless @transaction && @transaction.active?
            raise ClientError, "No active transaction"
          end

          @connection.send_rollback
          @transaction.mark_rolled_back
          @stats[:transactions_rolled_back] += 1

          @transaction = nil
        end
      end

      def in_transaction?
        @transaction && @transaction.active?
      end

      def ping
        @lock.synchronize do
          ensure_connected
          @connection.send_ping
          true
        end
      end

      def stats
        @lock.synchronize do
          @stats.merge({
            connected: @connected,
            host: @config[:host],
            port: @config[:port],
            database: @config[:database],
            pool_size: @config[:pool_size],
            pool_active: @pool ? @pool.active_count : 0
          })
        end
      end

      private

      def ensure_connected
        connect unless @connected
        raise ClientError, "Not connected" unless @connected
      end
    end
  end
end
