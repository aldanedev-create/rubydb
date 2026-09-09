# frozen_string_literal: true

require "securerandom"
require "time"

module RubyDB
  module Server
    # Session - Represents a client session
    class Session
      # A request-scoped cancellation token. Cancellation is deliberately
      # cooperative: executors observe it at bounded points and unwind the
      # request without killing a Ruby thread while it owns engine state.
      class CancellationToken
        def initialize
          @lock = Mutex.new
          @cancelled = false
        end

        def cancel!
          @lock.synchronize { @cancelled = true }
        end

        def cancelled?
          @lock.synchronize { @cancelled }
        end
      end

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
        @permissions = nil
        @transaction = nil
        @prepared_statements = {}
        @cursors = {}
        @variables = {}
        @is_active = true
        @lock = Mutex.new
        @operations_lock = Mutex.new
        @operations = {}
        @pending_cancellations = {}
      end

      def authenticate(credentials)
        @lock.synchronize do
          @username = credentials[:username]
          @database = credentials[:database] || "rubydb"
          @permissions = resolve_permissions(@username)
          @last_activity = Time.now
          true
        end
      end

      def process(request)
        return process_cancel(request) if request[:type].to_s == "cancel"

        @lock.synchronize do
          @last_activity = Time.now
          if request[:deadline_at] && Time.now >= Time.parse(request[:deadline_at].to_s)
            return { success: false, error: "Request deadline exceeded before execution", code: "deadline_exceeded" }
          end

          request_id = request[:request_id].to_s
          request_id = "local_#{object_id}_#{Time.now.to_f}" if request_id.empty?
          cancellation = CancellationToken.new
          @operations_lock.synchronize do
            @operations[request_id] = cancellation
            cancellation.cancel! if @pending_cancellations.delete(request_id)
          end

          begin
            case request[:type]
            when "query"
              process_query(request[:sql], request[:params] || [], request[:deadline_at], cancellation)
          when "prepare"
            process_prepare(request[:sql])
            when "execute"
              process_execute(request[:statement_id], request[:params] || [], request[:deadline_at], cancellation)
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
          rescue RubyDB::ExecutionError => error
            raise unless %w[deadline_exceeded cancelled].include?(error.code.to_s)

            { success: false, error: error.message, code: error.code.to_s }
          ensure
            @operations_lock.synchronize { @operations.delete(request_id) }
          end
        end
      end

      def cancel(request_id, allow_pending: false)
        token = @operations_lock.synchronize do
          key = request_id.to_s
          current = @operations[key]
          @pending_cancellations[key] = true if !current && allow_pending
          current
        end

        token&.cancel!
        true
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

      def process_cancel(request)
        target = request[:target_request_id] || request[:request_id]
        cancelled = cancel(target, allow_pending: request[:allow_pending_cancellation] == true)
        {
          success: cancelled,
          type: "cancel_response",
          target_request_id: target,
          cancelled: cancelled,
          code: cancelled ? "cancel_requested" : "request_not_found",
          timestamp: Time.now.iso8601
        }
      end

      def process_query(sql, params, deadline_at = nil, cancellation = nil)
        permission_error = authorize_sql(sql)
        return permission_error if permission_error

        {
          success: true,
          type: "query_result",
          result: execute_sql(sql, params, deadline_at: deadline_at, cancellation: cancellation),
          timestamp: Time.now.iso8601
        }
      end

      def process_prepare(sql)
        permission_error = authorize_sql(sql)
        return permission_error if permission_error

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

      def process_execute(stmt_id, params, deadline_at = nil, cancellation = nil)
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
          result: execute_sql(stmt[:sql], params, deadline_at: deadline_at, cancellation: cancellation),
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

        engine = @config[:engine]
        transaction_id = engine&.begin_transaction || "txn_#{Time.now.to_i}"
        @transaction = {
          id: transaction_id,
          started_at: Time.now,
          active: true,
          rollback: lambda do
            engine&.rollback_transaction
            @transaction = nil
          end
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

        committed = @config[:engine]&.commit_transaction
        unless committed
          return {
            success: false,
            error: "Transaction commit failed",
            commit_ack: @config[:engine]&.last_commit_ack
          }
        end
        @transaction[:active] = false
        @transaction = nil

        {
          success: true,
          type: "commit_result",
          committed: true,
          durable: @config[:engine]&.last_commit_ack&.fetch(:status, nil) == :durable,
          commit_ack: @config[:engine]&.last_commit_ack,
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
        @config[:engine]&.rollback_transaction
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

      def execute_sql(sql, params, deadline_at: nil, cancellation: nil)
        engine = @config[:engine]
        raise RubyDB::ServerError, "Session has no database engine" unless engine

        tokens = RubyDB::SQL::Lexer.new(sql).tokenize
        statements = RubyDB::SQL::Parser.new(tokens).parse
        results = statements.map do |statement|
          plan = RubyDB::Execution::Planner.new(engine).plan(statement)
          RubyDB::Execution::Executor.new(
            engine,
            deadline_at: deadline_at,
            cancellation: cancellation
          ).execute(plan)
        end
        results.size == 1 ? results.first : results
      end

      def resolve_permissions(username)
        policy = @config[:authorization] || @config["authorization"]
        return %i[read write] unless policy

        users = policy[:users] || policy["users"] || {}
        symbol_username = username.respond_to?(:to_sym) ? username.to_sym : username
        definition = users[username] || users[username.to_s] || users[symbol_username]
        permissions = definition.is_a?(Hash) ? (definition[:permissions] || definition["permissions"]) : definition
        Array(permissions).map(&:to_sym)
      end

      def authorize_sql(sql)
        required = sql.to_s.strip.split(/\s+/, 2).first.to_s.downcase
        permission = %w[select show explain].include?(required) ? :read : :write
        return nil if @permissions&.include?(permission)

        {
          success: false,
          error: "Permission denied: #{permission} access is required",
          timestamp: Time.now.iso8601
        }
      end
    end
  end
end
