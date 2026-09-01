# frozen_string_literal: true

require_relative "quoting"
require_relative "result"
require_relative "type"

module RubyDB
  module Rails
    # Connection - Rails database connection
    class Connection
      attr_reader :config, :client, :logger, :transaction

      include Quoting

      def initialize(config)
        @config = config
        @logger = config[:logger]
        @client = nil
        @transaction = nil
        @transaction_depth = 0
        @statements = {}
        @statement_counter = 0
        @connected = false
        @lock = Mutex.new
        @query_cache = {}
        @query_cache_enabled = false
        @query_cache_size = 100
        @last_query_time = nil
      end

      def connect
        @lock.synchronize do
          return if @connected

          @client = RubyDB::Client::Client.new(
            host: @config[:host] || "localhost",
            port: @config[:port] || 7432,
            username: @config[:username] || "rubydb",
            password: @config[:password] || "",
            database: @config[:database] || "rubydb",
            timeout: @config[:timeout] || 30,
            pool_size: @config[:pool_size] || 1
          )
          @client.connect
          @connected = true
        end
      end

      def disconnect
        @lock.synchronize do
          return unless @connected

          @client&.disconnect
          @connected = false
          @statements.clear
        end
      end

      def connected?
        @connected && @client&.connected?
      end

      def execute(sql, params = [])
        ensure_connected

        if @query_cache_enabled && sql =~ /^SELECT/i
          cache_key = "#{sql}:#{params.join(':')}"
          if @query_cache.key?(cache_key)
            return @query_cache[cache_key]
          end
        end

        result = @client.query(sql, params)
        rails_result = Result.new(result.to_hash)

        if @query_cache_enabled && sql =~ /^SELECT/i && @query_cache.size < @query_cache_size
          @query_cache[cache_key] = rails_result
        end

        rails_result
      end

      def prepare(sql)
        ensure_connected
        @client.prepare(sql)
      end

      def execute_prepared(statement_id, params = [])
        ensure_connected
        result = @client.execute(statement_id, params)
        Result.new(result.to_hash)
      end

      def close_statement(statement_id)
        ensure_connected
        @client.close_statement(statement_id)
      end

      def begin_db_transaction
        ensure_connected
        @transaction_depth += 1
        @client.begin_transaction if @transaction_depth == 1
      end

      def commit_db_transaction
        ensure_connected
        return if @transaction_depth <= 0

        @transaction_depth -= 1
        @client.commit if @transaction_depth == 0
      end

      def rollback_db_transaction
        ensure_connected
        return if @transaction_depth <= 0

        @transaction_depth -= 1
        @client.rollback if @transaction_depth == 0
        @transaction_depth = 0 if @transaction_depth < 0
      end

      def in_transaction?
        @transaction_depth > 0
      end

      def enable_query_cache
        @query_cache_enabled = true
        @query_cache.clear
      end

      def disable_query_cache
        @query_cache_enabled = false
        @query_cache.clear
      end

      def clear_query_cache
        @query_cache.clear
      end

      def quote(value, column = nil)
        super
      end

      def quote_table_name(name)
        super
      end

      def quote_column_name(name)
        super
      end

      def type_for(column)
        Type.to_rails(column.type)
      end

      def type_cast(value, type)
        Type.serialize(value, type)
      end

      def log(sql, name = nil, &block)
        start_time = Time.now
        result = block.call
        elapsed_ms = (Time.now - start_time) * 1000
        @last_query_time = elapsed_ms

        if @logger
          @logger.debug "  #{name || 'SQL'} (#{elapsed_ms.round(2)}ms) #{sql}"
        end

        result
      end

      def stats
        {
          connected: @connected,
          transaction_depth: @transaction_depth,
          statements: @statements.size,
          query_cache_size: @query_cache.size,
          query_cache_enabled: @query_cache_enabled,
          last_query_time: @last_query_time
        }
      end

      private

      def ensure_connected
        connect unless @connected
        raise ConnectionError, "Not connected" unless @connected
      end
    end
  end
end