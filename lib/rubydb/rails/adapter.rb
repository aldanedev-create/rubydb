# frozen_string_literal: true

require_relative "connection"
require_relative "database_statements"
require_relative "schema_statements"
require_relative "quoting"
require_relative "type"
require_relative "transaction"
require_relative "migration"
require_relative "result"

module RubyDB
  module Rails
    # Adapter - Rails database adapter
    class Adapter
      attr_reader :config, :connection, :logger

      include DatabaseStatements
      include SchemaStatements
      include Quoting

      ADAPTER_NAME = "RubyDB"

      def initialize(config)
        @config = config
        @logger = config[:logger]
        @connection = Connection.new(config)
        @connection.connect
        @pool = nil
        @statements = {}
        @statement_counter = 0
        @prepared_statements = {}
        @transaction = nil
        @lock = Mutex.new
      end

      def self.new(config)
        adapter = allocate
        adapter.send(:initialize, config)
        adapter
      end

      def adapter_name
        ADAPTER_NAME
      end

      def supports_migrations?
        true
      end

      def supports_primary_key?
        true
      end

      def supports_index_sort_order?
        true
      end

      def supports_transactions?
        true
      end

      def supports_savepoints?
        true
      end

      def supports_foreign_keys?
        true
      end

      def supports_views?
        true
      end

      def supports_json?
        true
      end

      def supports_uuid?
        true
      end

      def primary_key(table_name)
        result = execute("SELECT name FROM pragma_table_info(?)", [table_name])
        row = result.find { |r| r["pk"] == 1 }
        row ? row["name"] : "id"
      end

      def tables
        result = execute("SELECT name FROM sqlite_master WHERE type='table'")
        result.map { |row| row["name"] }
      end

      def table_exists?(table_name)
        tables.include?(table_name)
      end

      def indexes(table_name)
        result = execute("SELECT name, sql FROM sqlite_master WHERE type='index' AND tbl_name=?", [table_name])
        result.map do |row|
          {
            name: row["name"],
            columns: parse_index_columns(row["sql"])
          }
        end
      end

      def columns(table_name)
        result = execute("PRAGMA table_info(?)", [table_name])
        result.map do |row|
          {
            name: row["name"],
            type: row["type"],
            default: row["default"],
            null: row["notnull"] == 0,
            primary_key: row["pk"] == 1
          }
        end
      end

      def column_exists?(table_name, column_name)
        columns(table_name).any? { |c| c[:name] == column_name }
      end

      def schema_version
        result = execute("SELECT version FROM schema_migrations ORDER BY version DESC LIMIT 1")
        result.first ? result.first["version"] : nil
      end

      def dump_schema
        schema = ""

        tables.each do |table|
          schema << "create_table \"#{table}\" do |t|\n"
          columns(table).each do |col|
            next if col[:primary_key]
            type = Type.to_rails(col[:type])
            schema << "  t.#{type} \"#{col[:name]}\""
            schema << ", default: #{quote(col[:default])}" if col[:default]
            schema << ", null: false" unless col[:null]
            schema << "\n"
          end
          schema << "end\n\n"
        end

        schema
      end

      def reconnect!
        @connection.disconnect
        @connection.connect
      end

      def disconnect!
        @connection.disconnect
      end

      def reset!
        reconnect!
        @statements.clear
        @prepared_statements.clear
      end

      def close
        @connection.disconnect
      end

      def active?
        @connection.connected?
      end

      def stats
        @connection.stats
      end

      private

      def parse_index_columns(sql)
        if sql =~ /\(([^)]+)\)/
          $1.split(",").map(&:strip)
        else
          []
        end
      end

      def log(sql, name = nil, &block)
        start_time = Time.now
        result = block.call
        elapsed_ms = (Time.now - start_time) * 1000

        if @logger
          @logger.debug "  #{name || 'SQL'} (#{elapsed_ms.round(2)}ms) #{sql}"
        end

        result
      end
    end
  end
end