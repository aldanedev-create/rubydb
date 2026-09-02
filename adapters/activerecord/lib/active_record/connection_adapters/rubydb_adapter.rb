# frozen_string_literal: true

require "active_record"
require "active_record/connection_adapters/abstract_adapter"
require "active_record/connection_adapters/abstract/schema_definitions"
require "active_record/connection_adapters/abstract/schema_statements"

require "rubydb"
require "rubydb/rails/adapter"
require "rubydb/rails/connection"
require "rubydb/rails/database_statements"
require "rubydb/rails/schema_statements"
require "rubydb/rails/quoting"
require "rubydb/rails/type"
require "rubydb/rails/result"

module ActiveRecord
  module ConnectionAdapters
    # RubyDB adapter for ActiveRecord
    class RubyDBAdapter < AbstractAdapter
      include RubyDB::Rails::DatabaseStatements
      include RubyDB::Rails::SchemaStatements
      include RubyDB::Rails::Quoting

      ADAPTER_NAME = "RubyDB"

      NATIVE_DATABASE_TYPES = {
        primary_key: "INTEGER PRIMARY KEY AUTOINCREMENT",
        string: { name: "VARCHAR", limit: 255 },
        text: { name: "TEXT" },
        integer: { name: "INTEGER" },
        bigint: { name: "BIGINT" },
        smallint: { name: "SMALLINT" },
        float: { name: "FLOAT" },
        decimal: { name: "DECIMAL", precision: 10, scale: 2 },
        datetime: { name: "TIMESTAMP" },
        timestamp: { name: "TIMESTAMP" },
        time: { name: "TIME" },
        date: { name: "DATE" },
        binary: { name: "BLOB" },
        boolean: { name: "BOOLEAN" },
        json: { name: "JSON" },
        uuid: { name: "UUID" }
      }

      # ActiveRecord 7.2 constructs adapters with a single configuration hash.
      # Accept trailing deprecated arguments so applications upgrading from older
      # ActiveRecord versions do not fail during connection establishment.
      def initialize(config, *)
        super(config)

        @connection = RubyDB::Rails::Connection.new(config)
        @connection.connect

        @prepared_statements = {}
        @transaction_depth = 0
        @query_cache_enabled = false
        @query_cache = {}
        @statements = {}
        @statement_counter = 0
        # AbstractAdapter uses this monitor while creating transactions. It
        # must be re-entrant because ActiveRecord acquires it recursively.
        @lock = Monitor.new
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

      def supports_bulk_alter?
        true
      end

      def native_database_types
        NATIVE_DATABASE_TYPES
      end

      # ==================== SCHEMA METHODS ====================

      def primary_key(table_name)
        return @connection.engine.table_columns(table_name).find(&:primary_key?)&.name&.to_s || "id" if embedded?

        result = execute("PRAGMA table_info(#{quote_table_name(table_name)})")
        row = result.find { |r| r["pk"] == 1 }
        row ? row["name"] : "id"
      end

      def tables
        return @connection.engine.list_tables.map(&:to_s) if embedded?

        result = execute("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'")
        result.map { |row| row["name"] }
      end

      def table_exists?(table_name)
        tables.include?(table_name.to_s)
      end

      # ActiveRecord's schema cache asks for these before a model is first
      # instantiated. The embedded engine has catalog metadata already, so
      # avoid generating unsupported SQLite catalog queries.
      def data_sources
        return tables if embedded?

        super
      end

      def data_source_exists?(name)
        return table_exists?(name) if embedded?

        super
      end

      def views
        return [] if embedded?

        super
      end

      def indexes(table_name)
        result = execute("SELECT name, sql FROM sqlite_master WHERE type='index' AND tbl_name=?", [table_name])
        result.map do |row|
          {
            name: row["name"],
            columns: parse_index_columns(row["sql"]),
            unique: row["sql"].include?("UNIQUE")
          }
        end
      end

      def columns(table_name)
        return embedded_columns(table_name) if embedded?

        result = execute("PRAGMA table_info(#{quote_table_name(table_name)})")
        result.map do |row|
          ActiveRecord::ConnectionAdapters::Column.new(
            row["name"],
            row["default"],
            RubyDB::Rails::Type.to_rails(row["type"]),
            {
              null: row["notnull"] == 0,
              primary_key: row["pk"] == 1,
              limit: extract_limit(row["type"])
            }
          )
        end
      end

      def column_exists?(table_name, column_name)
        columns(table_name).any? { |c| c.name == column_name }
      end

      # ==================== QUERY METHODS ====================

      def execute(sql, name = nil)
        sql = sql_for_execution(sql)
        log(sql, name) do
          @connection.execute(sql)
        end
      end

      def exec_query(sql, name = nil, binds = [])
        sql = sql_for_execution(sql)
        warn "RubyDB ActiveRecord query: #{sql}" if ENV["RUBYDB_DEBUG_SQL"] == "1"
        log(sql, name) do
          params = binds.map { |bind| bind.value }
          active_record_result(@connection.execute(sql, params))
        end
      end

      def exec_delete(sql, name = nil, binds = [])
        sql = sql_for_execution(sql)
        log(sql, name) do
          params = binds.map { |bind| bind.value }
          result = @connection.execute(sql, params)
          result.affected_rows
        end
      end

      def exec_update(sql, name = nil, binds = [])
        sql = sql_for_execution(sql)
        log(sql, name) do
          params = binds.map { |bind| bind.value }
          result = @connection.execute(sql, params)
          result.affected_rows
        end
      end

      def exec_insert(sql, name = nil, binds = [], pk = nil, sequence_name = nil, returning: nil)
        sql = sql_for_execution(sql)
        log(sql, name) do
          params = binds.map { |bind| bind.value }
          result = @connection.execute(sql, params)
          id = result.row_id
          ActiveRecord::Result.new([pk || "id"], id.nil? ? [] : [[id]])
        end
      end

      def insert(arel, name = nil, pk = nil, id_value = nil, sequence_name = nil, binds = [], returning: nil)
        sql, binds = to_sql_and_binds(arel, binds)
        result = exec_insert(sql, name, binds, pk, sequence_name, returning: returning)
        return returning_column_values(result) unless returning.nil?

        id_value || last_inserted_id(result)
      end

      def update(arel, name = nil, binds = [])
        sql, binds = to_sql_and_binds(arel, binds)
        exec_update(sql, name, binds)
      end

      def delete(arel, name = nil, binds = [])
        sql, binds = to_sql_and_binds(arel, binds)
        exec_delete(sql, name, binds)
      end

      def select_all(sql, name = nil, binds = [], preparable: nil, async: false, allow_retry: false)
        exec_query(sql, name, binds)
      end

      def select_one(sql, name = nil, binds = [])
        result = exec_query(sql, name, binds)
        result.first
      end

      def select_value(sql, name = nil, binds = [])
        result = exec_query(sql, name, binds)
        result.first&.values&.first
      end

      def select_values(sql, name = nil, binds = [])
        result = exec_query(sql, name, binds)
        result.map { |row| row.values.first }
      end

      def select_rows(sql, name = nil, binds = [])
        result = exec_query(sql, name, binds)
        result.map { |row| row.values }
      end

      # ==================== TRANSACTION METHODS ====================

      def begin_db_transaction
        @transaction_depth += 1
        @connection.begin_db_transaction if @transaction_depth == 1
      end

      def commit_db_transaction
        return if @transaction_depth <= 0

        @transaction_depth -= 1
        @connection.commit_db_transaction if @transaction_depth == 0
      end

      def rollback_db_transaction
        return if @transaction_depth <= 0

        @transaction_depth -= 1
        @connection.rollback_db_transaction if @transaction_depth == 0
        @transaction_depth = 0 if @transaction_depth < 0
      end

      def create_savepoint(name)
        execute("SAVEPOINT #{name}")
      end

      def rollback_to_savepoint(name)
        execute("ROLLBACK TO SAVEPOINT #{name}")
      end

      def release_savepoint(name)
        execute("RELEASE SAVEPOINT #{name}")
      end

      def in_transaction?
        @transaction_depth > 0
      end

      def transaction_joinable?
        true
      end

      def transactional?
        true
      end

      # ==================== SCHEMA STATEMENT METHODS ====================

      def create_table(table_name, **options, &block)
        super
      end

      def drop_table(table_name, **options)
        sql = "DROP TABLE"
        sql << " IF EXISTS" if options[:if_exists]
        sql << " #{quote_table_name(table_name)}"
        sql << " CASCADE" if options[:cascade]
        execute(sql)
      end

      def add_column(table_name, column_name, type, **options)
        sql = "ALTER TABLE #{quote_table_name(table_name)}"
        sql << " ADD COLUMN #{quote_column_name(column_name)} #{type_to_sql(type, options)}"

        if options[:null] == false
          sql << " NOT NULL"
        end

        if options[:default]
          sql << " DEFAULT #{quote_default(options[:default])}"
        end

        if options[:primary_key]
          sql << " PRIMARY KEY"
        end

        execute(sql)
      end

      def remove_column(table_name, column_name, type = nil, **options)
        sql = "ALTER TABLE #{quote_table_name(table_name)}"
        sql << " DROP COLUMN #{quote_column_name(column_name)}"
        sql << " CASCADE" if options[:cascade]
        execute(sql)
      end

      def change_column(table_name, column_name, type, **options)
        # Change column type
        sql = "ALTER TABLE #{quote_table_name(table_name)}"
        sql << " ALTER COLUMN #{quote_column_name(column_name)}"
        sql << " TYPE #{type_to_sql(type, options)}"
        execute(sql)

        # Change nullability
        if options.key?(:null)
          sql = "ALTER TABLE #{quote_table_name(table_name)}"
          sql << " ALTER COLUMN #{quote_column_name(column_name)}"
          sql << (options[:null] ? " DROP" : " SET") + " NOT NULL"
          execute(sql)
        end

        # Change default
        if options.key?(:default)
          sql = "ALTER TABLE #{quote_table_name(table_name)}"
          sql << " ALTER COLUMN #{quote_column_name(column_name)}"
          if options[:default].nil?
            sql << " DROP DEFAULT"
          else
            sql << " SET DEFAULT #{quote_default(options[:default])}"
          end
          execute(sql)
        end
      end

      def rename_column(table_name, column_name, new_column_name)
        sql = "ALTER TABLE #{quote_table_name(table_name)}"
        sql << " RENAME COLUMN #{quote_column_name(column_name)}"
        sql << " TO #{quote_column_name(new_column_name)}"
        execute(sql)
      end

      def rename_table(old_name, new_name)
        sql = "ALTER TABLE #{quote_table_name(old_name)}"
        sql << " RENAME TO #{quote_table_name(new_name)}"
        execute(sql)
      end

      def add_index(table_name, column_name, **options)
        index_name = options[:name] || "idx_#{table_name}_#{Array(column_name).join('_')}"
        sql = "CREATE"
        sql << " UNIQUE" if options[:unique]
        sql << " INDEX #{quote_column_name(index_name)}"
        sql << " ON #{quote_table_name(table_name)}"
        sql << " (#{Array(column_name).map { |c| quote_column_name(c) }.join(', ')})"
        sql << " WHERE #{options[:where]}" if options[:where]
        execute(sql)
      end

      def remove_index(table_name, **options)
        index_name = options[:name]
        if index_name.nil?
          column_name = options[:column] || options[:columns]
          index_name = "idx_#{table_name}_#{Array(column_name).join('_')}"
        end

        sql = "DROP INDEX #{quote_column_name(index_name)}"
        sql << " ON #{quote_table_name(table_name)}"
        execute(sql)
      end

      def add_foreign_key(from_table, to_table, **options)
        fk_name = options[:name] || "fk_#{from_table}_to_#{to_table}"
        sql = "ALTER TABLE #{quote_table_name(from_table)}"
        sql << " ADD CONSTRAINT #{quote_column_name(fk_name)}"
        sql << " FOREIGN KEY (#{quote_column_name(options[:column] || :id)})"
        sql << " REFERENCES #{quote_table_name(to_table)}"
        sql << " (#{quote_column_name(options[:primary_key] || :id)})"
        sql << " ON DELETE #{options[:on_delete]}" if options[:on_delete]
        sql << " ON UPDATE #{options[:on_update]}" if options[:on_update]
        execute(sql)
      end

      def remove_foreign_key(from_table, **options)
        fk_name = options[:name] || "fk_#{from_table}_to_#{options[:to_table]}"
        sql = "ALTER TABLE #{quote_table_name(from_table)}"
        sql << " DROP CONSTRAINT #{quote_column_name(fk_name)}"
        execute(sql)
      end

      def add_timestamps(table_name, **options)
        add_column(table_name, :created_at, :datetime, options)
        add_column(table_name, :updated_at, :datetime, options)
      end

      def remove_timestamps(table_name, **options)
        remove_column(table_name, :updated_at, options)
        remove_column(table_name, :created_at, options)
      end

      def change_column_null(table_name, column_name, null, default = nil)
        if default
          sql = "UPDATE #{quote_table_name(table_name)}"
          sql << " SET #{quote_column_name(column_name)} = #{quote(default)}"
          sql << " WHERE #{quote_column_name(column_name)} IS NULL"
          execute(sql)
        end

        sql = "ALTER TABLE #{quote_table_name(table_name)}"
        sql << " ALTER COLUMN #{quote_column_name(column_name)}"
        sql << (null ? " DROP" : " SET") + " NOT NULL"
        execute(sql)
      end

      def change_column_default(table_name, column_name, default)
        sql = "ALTER TABLE #{quote_table_name(table_name)}"
        sql << " ALTER COLUMN #{quote_column_name(column_name)}"
        if default.nil?
          sql << " DROP DEFAULT"
        else
          sql << " SET DEFAULT #{quote_default(default)}"
        end
        execute(sql)
      end

      # ==================== QUOTING METHODS ====================

      def quote(value, column = nil)
        @connection.quote(value, column)
      end

      def quote_table_name(name)
        @connection.quote_table_name(name)
      end

      def quote_column_name(name)
        @connection.quote_column_name(name)
      end

      def quote_default(value)
        quote(value)
      end

      # ==================== TYPE CASTING ====================

      def type_cast(value, type)
        RubyDB::Rails::Type.serialize(value, type)
      end

      def type_cast_from_database(value, type)
        RubyDB::Rails::Type.deserialize(value, type)
      end

      # ==================== SCHEMA VERSION ====================

      def schema_version
        result = execute("SELECT version FROM schema_migrations ORDER BY version DESC LIMIT 1")
        result.first ? result.first["version"] : nil
      end

      def schema_migrations
        result = execute("SELECT version FROM schema_migrations ORDER BY version")
        result.map { |row| row["version"] }
      end

      def dump_schema
        schema = ""
        tables.each do |table|
          schema << "create_table \"#{table}\" do |t|\n"
          columns(table).each do |col|
            next if col.primary_key?
            type = RubyDB::Rails::Type.to_rails(col.type)
            schema << "  t.#{type} \"#{col.name}\""
            schema << ", default: #{quote(col.default)}" if col.default
            schema << ", null: false" unless col.null
            schema << "\n"
          end
          schema << "end\n\n"
        end
        schema
      end

      # ==================== CONNECTION MANAGEMENT ====================

      def reset!
        @connection.disconnect
        @connection.connect
        @prepared_statements.clear
        @query_cache.clear
        @statements.clear
      end

      def disconnect!
        @connection.disconnect
      end

      def reconnect!
        reset!
      end

      def active?
        @connection.connected?
      end

      def close
        @connection.disconnect
      end

      # ==================== QUERY CACHE ====================

      def clear_cache!
        @query_cache.clear
      end

      def enable_query_cache!
        @query_cache_enabled = true
        @query_cache.clear
      end

      def disable_query_cache!
        @query_cache_enabled = false
        @query_cache.clear
      end

      def query_cache_enabled
        @query_cache_enabled
      end

      # ==================== PREPARED STATEMENTS ====================

      def prepare_statement(sql)
        @lock.synchronize do
          stmt_id = "stmt_#{Time.now.to_i}_#{@statement_counter}"
          @statement_counter += 1

          result = @connection.prepare(sql)
          @prepared_statements[stmt_id] = {
            id: result.statement_id,
            sql: sql,
            created_at: Time.now
          }

          stmt_id
        end
      end

      def execute_prepared_statement(stmt_id, params = [])
        @lock.synchronize do
          stmt = @prepared_statements[stmt_id]
          return nil unless stmt

          @connection.execute_prepared(stmt[:id], params)
        end
      end

      def close_statement(stmt_id)
        @lock.synchronize do
          stmt = @prepared_statements.delete(stmt_id)
          if stmt
            @connection.close_statement(stmt[:id])
          end
        end
      end

      # ==================== VERSION INFORMATION ====================

      def dbms_version
        RubyDB::VERSION
      end

      # ==================== FEATURE SUPPORT ====================

      def supports_datetime_with_precision?
        true
      end

      def supports_materialized_views?
        false
      end

      def supports_common_table_expressions?
        true
      end

      # ==================== PRIVATE METHODS ====================

      private

      def embedded?
        !@connection.engine.nil?
      end

      def embedded_columns(table_name)
        @connection.engine.table_columns(table_name).map do |column|
          ActiveRecord::ConnectionAdapters::Column.new(
            column.name.to_s,
            column.has_default? ? column.default : nil,
            ActiveRecord::ConnectionAdapters::SqlTypeMetadata.new(
              sql_type: column.type.to_s.upcase,
              type: rails_type_for(column.type),
              limit: column.options[:limit]
            ),
            column.nullable?
          )
        end
      end

      def rails_type_for(type)
        case type.to_sym
        when :integer, :bigint, :smallint then :integer
        when :float then :float
        when :decimal then :decimal
        when :boolean then :boolean
        when :date then :date
        when :time then :time
        when :datetime, :timestamp then :datetime
        when :binary, :blob then :binary
        when :json then :json
        else :string
        end
      end

      def sql_for_execution(sql)
        sql = sql.to_sql if sql.respond_to?(:to_sql)
        # RubyDB's SQL parser currently accepts unqualified column names.
        # ActiveRecord emits quoted table-qualified names for even the simplest
        # model lookup, so strip only the qualifier from generated identifiers.
        sql = sql.gsub(/(?:"[^"]+"|[A-Za-z_][A-Za-z0-9_]*)\.\*/, "*")
        sql.gsub(/(?:"[^"]+"|[A-Za-z_][A-Za-z0-9_]*)\.(?="[^"]+"|[A-Za-z_][A-Za-z0-9_]*)/, "")
      end

      def active_record_result(result)
        rows = result.to_a
        columns = result.columns.map do |column|
          column.is_a?(Hash) ? (column[:name] || column["name"] || column) : column
        end.map(&:to_s)
        columns = rows.first.keys.map(&:to_s) if columns.empty? && rows.first.respond_to?(:keys)
        values = rows.map do |row|
          columns.map { |column| row[column] || row[column.to_sym] }
        end
        ActiveRecord::Result.new(columns, values)
      end

      def parse_index_columns(sql)
        if sql =~ /\(([^)]+)\)/
          $1.split(",").map(&:strip)
        else
          []
        end
      end

      def extract_limit(type)
        if type =~ /VARCHAR\((\d+)\)/
          $1.to_i
        else
          nil
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

      def type_to_sql(type, options = {})
        case type.to_sym
        when :integer
          "INTEGER"
        when :bigint
          "BIGINT"
        when :smallint
          "SMALLINT"
        when :float
          "FLOAT"
        when :decimal
          precision = options[:precision] || 10
          scale = options[:scale] || 2
          "DECIMAL(#{precision}, #{scale})"
        when :boolean
          "BOOLEAN"
        when :text
          "TEXT"
        when :string
          limit = options[:limit] || 255
          "VARCHAR(#{limit})"
        when :binary
          "BLOB"
        when :date
          "DATE"
        when :time
          "TIME"
        when :datetime, :timestamp
          "TIMESTAMP"
        when :json
          "JSON"
        when :uuid
          "UUID"
        else
          "TEXT"
        end
      end
    end
  end
end

# Register the adapter with ActiveRecord
ActiveRecord::ConnectionAdapters.register("rubydb", "ActiveRecord::ConnectionAdapters::RubyDBAdapter")
