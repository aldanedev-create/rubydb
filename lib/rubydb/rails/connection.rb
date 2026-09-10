# frozen_string_literal: true

require_relative "quoting"
require_relative "result"
require_relative "type"

module RubyDB
  module Rails
    # Connection - Rails database connection
    class Connection
      attr_reader :config, :client, :engine, :logger, :transaction

      include Quoting

      def initialize(config)
        @config = config
        @engine = config[:engine]
        @engine_owned = false
        if @engine.nil? && embedded_config?
          @engine = build_embedded_engine
          @engine_owned = true
        end
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

          if @engine.nil? && embedded_config?
            @engine = build_embedded_engine
            @engine_owned = true
          end

          if @engine
            if @engine.respond_to?(:open?) && !@engine.open?
              raise ConnectionError, "Embedded RubyDB engine is not open"
            end
            @connected = true
            return
          end

          url = @config[:url] || @config["url"]
          client_config = if url
            {url: url}
          else
            {
              host: @config[:host] || "localhost",
              port: @config[:port] || 7432,
              username: @config[:username] || "rubydb",
              password: @config[:password] || "",
              database: @config[:database] || "rubydb"
            }
          end
          client_config[:timeout] = @config[:timeout] || @config["timeout"] || 30
          client_config[:pool_size] = @config[:pool_size] || 1
          client_config[:ssl] = @config[:ssl] || @config["ssl"] if @config[:ssl] || @config["ssl"]
          client_config[:compress] = @config[:compress] || @config["compress"] if @config[:compress] || @config["compress"]
          client_config[:format] = @config[:format] || @config["format"] if @config[:format] || @config["format"]
          @client = RubyDB::Client::Client.new(client_config)
          @client.connect
          @connected = true
        end
      end

      def disconnect
        @lock.synchronize do
          return unless @connected

          @client&.disconnect unless @engine
          if @engine_owned && @engine.respond_to?(:open?) && @engine.open?
            @engine.close
            @engine = nil
          end
          @connected = false
          @statements.clear
        end
      end

      def connected?
        return @connected && (!@engine.respond_to?(:open?) || @engine.open?) if @engine

        @connected && @client&.connected?
      end

      def execute(sql, params = [])
        ensure_connected

        if @query_cache_enabled && sql =~ /^SELECT/i
          cache_key = "#{sql}:#{params.join(":")}"
          if @query_cache.key?(cache_key)
            return @query_cache[cache_key]
          end
        end

        rails_result = if @engine
          Result.new(execute_embedded(sql, params))
        else
          result = @client.query(sql, params)
          Result.new(result.to_hash)
        end

        if @query_cache_enabled && sql =~ /^SELECT/i && @query_cache.size < @query_cache_size
          @query_cache[cache_key] = rails_result
        end

        rails_result
      end

      def prepare(sql)
        ensure_connected
        if @engine
          @statement_counter += 1
          @statements[@statement_counter] = sql
          return @statement_counter
        end
        @client.prepare(sql)
      end

      def execute_prepared(statement_id, params = [])
        ensure_connected
        return execute(@statements.fetch(statement_id), params) if @engine

        result = @client.execute(statement_id, params)
        Result.new(result.to_hash)
      end

      def close_statement(statement_id)
        ensure_connected
        return @statements.delete(statement_id) if @engine

        @client.close_statement(statement_id)
      end

      def begin_db_transaction
        ensure_connected
        @transaction_depth += 1
        if @engine && @transaction_depth == 1
          @engine.begin_transaction
          @transaction = @engine.current_transaction
        end
        @client.begin_transaction if !@engine && @transaction_depth == 1
      end

      def commit_db_transaction
        ensure_connected
        return if @transaction_depth <= 0

        @transaction_depth -= 1
        if @transaction_depth == 0
          @engine&.commit_transaction(@transaction)
          @client.commit unless @engine
          @transaction = nil
        end
      end

      def rollback_db_transaction
        ensure_connected
        return if @transaction_depth <= 0

        @transaction_depth -= 1
        if @transaction_depth == 0
          @engine&.rollback_transaction(@transaction)
          @client.rollback unless @engine
          @transaction = nil
        end
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

        @logger&.debug "  #{name || "SQL"} (#{elapsed_ms.round(2)}ms) #{sql}"

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

      def execute_embedded(sql, params)
        bound_sql = bind_parameters(sql, params)
        statements = RubyDB::SQL::Parser.new(RubyDB::SQL::Lexer.new(bound_sql).tokenize).parse
        results = statements.map do |statement|
          plan = RubyDB::Execution::Planner.new(@engine).plan(statement)
          RubyDB::Execution::Executor.new(@engine).execute(plan)
        end
        (results.size == 1) ? results.first : {rows: results, row_count: results.size}
      end

      def bind_parameters(sql, params)
        return sql if params.empty?

        index = 0
        used_indices = []
        quoted = false
        result = +""
        position = 0

        while position < sql.length
          char = sql[position]
          if char == "'"
            if quoted && sql[position + 1] == "'"
              result << "''"
              position += 2
              next
            end
            quoted = !quoted
            result << char
          elsif char == "?" && !quoted
            raise ArgumentError, "Not enough bind parameters" if index >= params.size

            result << quote(params[index])
            used_indices << index
            index += 1
          elsif char == "$" && !quoted && (placeholder = sql[position..].match(/\A\$(\d+)/))
            parameter_index = placeholder[1].to_i - 1
            raise ArgumentError, "Bind parameter #{parameter_index + 1} is out of range" if parameter_index.negative? || parameter_index >= params.size

            result << quote(params[parameter_index])
            used_indices << parameter_index
            position += placeholder[0].length - 1
          else
            result << char
          end
          position += 1
        end
        raise ArgumentError, "Too many bind parameters" unless used_indices.uniq.size == params.size

        result
      end

      def ensure_connected
        connect unless @connected
        raise ConnectionError, "Not connected" unless @connected
      end

      def embedded_config?
        @config[:embedded] || @config["embedded"]
      end

      def build_embedded_engine
        database = @config[:database] || @config["database"]
        raise ConnectionError, "Embedded RubyDB requires a database path" if database.nil? || database.to_s.empty?

        RubyDB::Storage::Engine.new(database.to_s, auto_cleanup: false, auto_vacuum: false)
      end
    end
  end
end
