# frozen_string_literal: true

require "securerandom"

module RubyDB
  module Server
    # Session - Represents a client session
    class Session
      attr_reader :id, :connection, :created_at, :last_activity
      attr_reader :username, :database, :transaction

      def initialize(connection, config = {})
        @id = generate_session_id
        @connection = connection
        @config = config
        @created_at = Time.now
        @last_activity = Time.now
        @username = nil
        @database = nil
        @transaction = nil
        @prepared_statements = {}
        @cursors = {}
        @variables = {}
        @is_active = true
        @lock = Mutex.new
      end

      def authenticate(credentials)
        @lock.synchronize do
          @username = credentials[:username]
          @database = credentials[:database] || "rubydb"
          @last_activity = Time.now
          true
        end
      end

      def process(request)
        @lock.synchronize do
          @last_activity = Time.now

          case request[:type]
          when "query"
            process_query(request[:sql], request[:params] || [])
          when "prepare"
            process_prepare(request[:sql])
          when "execute"
            process_execute(request[:statement_id], request[:params] || [])
          when "close"
            process_close(request[:statement_id])
          when "begin"
            process_begin
          when "commit"
            process_commit
          when "rollback"
            process_rollback
          when "ping"
            process_ping
          else
            { success: false, error: "Unknown request type: #{request[:type]}" }
          end
        end
      end

      def close
        @lock.synchronize do
          @is_active = false

          # Close all prepared statements
          @prepared_statements.each do |id, stmt|
            stmt[:close].call if stmt[:close]
          end
          @prepared_statements.clear

          # Close all cursors
          @cursors.each do |id, cursor|
            cursor[:close].call if cursor[:close]
          end
          @cursors.clear

          # Rollback transaction if active
          if @transaction && @transaction[:active]
            @transaction[:rollback].call if @transaction[:rollback]
          end
          @transaction = nil

          true
        end
      end

      def active?
        @is_active
      end

      def to_hash
        {
          id: @id,
          username: @username,
          database: @database,
          created_at: @created_at.iso8601,
          last_activity: @last_activity.iso8601,
          prepared_statements: @prepared_statements.size,
          cursors: @cursors.size,
          variables: @variables.size,
          in_transaction: @transaction && @transaction[:active],
          active: @is_active
        }
      end

      private

      def generate_session_id
        "sess_#{Time.now.to_i}_#{SecureRandom.hex(8)}"
      end

      def process_query(sql, params)
        {
          success: true,
          type: "query_result",
          result: execute_sql(sql, params),
          timestamp: Time.now.iso8601
        }
      end

      def process_prepare(sql)
        stmt_id = "stmt_#{Time.now.to_i}_#{SecureRandom.hex(4)}"
        @prepared_statements[stmt_id] = {
          sql: sql,
          created_at: Time.now,
          close: lambda { @prepared_statements.delete(stmt_id) }
        }

        {
          success: true,
          type: "prepare_result",
          statement_id: stmt_id,
          timestamp: Time.now.iso8601
        }
      end

      def process_execute(stmt_id, params)
        stmt = @prepared_statements[stmt_id]
        unless stmt
          return {
            success: false,
            error: "Statement not found: #{stmt_id}"
          }
        end

        {
          success: true,
          type: "execute_result",
          result: execute_sql(stmt[:sql], params),
          timestamp: Time.now.iso8601
        }
      end

      def process_close(stmt_id)
        @prepared_statements.delete(stmt_id)

        {
          success: true,
          type: "close_result",
          timestamp: Time.now.iso8601
        }
      end

      def process_begin
        if @transaction && @transaction[:active]
          return {
            success: false,
            error: "Transaction already active"
          }
        end

        @transaction = {
          id: "txn_#{Time.now.to_i}",
          started_at: Time.now,
          active: true,
          rollback: lambda { @transaction = nil }
        }

        {
          success: true,
          type: "begin_result",
          transaction_id: @transaction[:id],
          timestamp: Time.now.iso8601
        }
      end

      def process_commit
        unless @transaction && @transaction[:active]
          return {
            success: false,
            error: "No active transaction"
          }
        end

        @transaction[:active] = false
        @transaction = nil

        {
          success: true,
          type: "commit_result",
          timestamp: Time.now.iso8601
        }
      end

      def process_rollback
        unless @transaction && @transaction[:active]
          return {
            success: false,
            error: "No active transaction"
          }
        end

        @transaction[:active] = false
        @transaction = nil

        {
          success: true,
          type: "rollback_result",
          timestamp: Time.now.iso8601
        }
      end

      def process_ping
        {
          success: true,
          type: "pong",
          timestamp: Time.now.iso8601,
          session_id: @id
        }
      end

      def execute_sql(sql, params)
        # In production, this would use the engine to execute SQL
        {
          rows: [],
          row_count: 0,
          columns: []
        }
      end
    end
  end
end