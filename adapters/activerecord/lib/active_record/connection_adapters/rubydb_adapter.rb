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

      # ActiveRecord 7.2 uses adapter-level methods while compiling hash-form
      # order clauses (for example, `order(created_at: :desc)`). Keep these
      # independent of a live connection so relation construction is safe
      # during schema-cache and query setup as well.
      def self.quote_table_name(name)
        quote_column_name(name)
      end

      def self.quote_column_name(name)
        "\"#{name.to_s.gsub('"', '""')}\""
      end

      NATIVE_DATABASE_TYPES = {
        primary_key: "INTEGER PRIMARY KEY AUTOINCREMENT",
        string: {name: "VARCHAR", limit: 255},
        text: {name: "TEXT"},
        integer: {name: "INTEGER"},
        bigint: {name: "BIGINT"},
        smallint: {name: "SMALLINT"},
        float: {name: "FLOAT"},
        decimal: {name: "DECIMAL", precision: 10, scale: 2},
        datetime: {name: "TIMESTAMP"},
        timestamp: {name: "TIMESTAMP"},
        time: {name: "TIME"},
        date: {name: "DATE"},
        binary: {name: "BLOB"},
        boolean: {name: "BOOLEAN"},
        json: {name: "JSON"},
        uuid: {name: "UUID"}
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
        false
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
        if embedded?
          return @connection.engine.index_manager.get_indexes_for_table(table_name.to_s).map do |index|
            ActiveRecord::ConnectionAdapters::IndexDefinition.new(
              table_name.to_s,
              index.name.to_s,
              index.unique,
              index.columns.map(&:to_s)
            )
          end
        end

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
        log(sql, name) do
          params = bind_values(binds)
          active_record_result(@connection.execute(sql, params))
        end
      end

      def exec_delete(sql, name = nil, binds = [])
        sql = sql_for_execution(sql)
        log(sql, name) do
          params = bind_values(binds)
          result = @connection.execute(sql, params)
          result.affected_rows
        end
      end

      def exec_update(sql, name = nil, binds = [])
        sql = sql_for_execution(sql)
        log(sql, name) do
          params = bind_values(binds)
          result = @connection.execute(sql, params)
          result.affected_rows
        end
      end

      def exec_insert(sql, name = nil, binds = [], pk = nil, sequence_name = nil, returning: nil)
        sql = sql_for_execution(sql)
        log(sql, name) do
          params = bind_values(binds)
          result = @connection.execute(sql, params)
          # RubyDB keeps a physical row id for storage operations and a
          # logical primary-key value for SQL/ActiveRecord. They can differ
          # after deletes, so ActiveRecord must receive the logical id.
          id = result.inserted_id || result.row_id
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
        sql, binds = to_sql_and_binds(sql, binds)
        exec_query(sql, name, binds)
      end

      def select_one(sql, name = nil, binds = [])
        sql, binds = to_sql_and_binds(sql, binds)
        result = exec_query(sql, name, binds)
        result.first
      end

      def select_value(sql, name = nil, binds = [])
        sql, binds = to_sql_and_binds(sql, binds)
        result = exec_query(sql, name, binds)
        result.first&.values&.first
      end

      def select_values(sql, name = nil, binds = [])
        sql, binds = to_sql_and_binds(sql, binds)
        result = exec_query(sql, name, binds)
        result.map { |row| row.values.first }
      end

      def select_rows(sql, name = nil, binds = [])
        sql, binds = to_sql_and_binds(sql, binds)
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

      def create_table(table_name, **options, &)
        RubyDB::Rails::SchemaStatements.instance_method(:create_table).bind_call(self, table_name, options, &)
      end

      def drop_table(table_name, **options)
        sql = +"DROP TABLE"
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
          sql << if options[:default].nil?
            " DROP DEFAULT"
          else
            " SET DEFAULT #{quote_default(options[:default])}"
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
        index_name = options[:name] || "idx_#{table_name}_#{Array(column_name).join("_")}"
        sql = +"CREATE"
        sql << " UNIQUE" if options[:unique]
        sql << " INDEX #{quote_column_name(index_name)}"
        sql << " ON #{quote_table_name(table_name)}"
        sql << " (#{Array(column_name).map { |c| quote_column_name(c) }.join(", ")})"
        sql << " WHERE #{options[:where]}" if options[:where]
        execute(sql)
      end

      def remove_index(table_name, column_name = nil, **options)
        index_name = options[:name]
        if index_name.nil?
          column_name ||= options[:column] || options[:columns]
          index_name = "idx_#{table_name}_#{Array(column_name).join("_")}"
        end

        sql = "DROP INDEX #{quote_column_name(index_name)}"
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

      def foreign_keys(table_name)
        return super unless embedded?

        constraints = @connection.engine.table_metadata[table_name.to_s]&.fetch(:constraints, []) || []
        constraints.filter_map do |constraint|
          type = constraint[:type] || constraint["type"]
          next unless type.to_s.upcase == "FOREIGN_KEY"

          columns = constraint[:columns] || constraint["columns"] || []
          reference_table = constraint[:reference_table] || constraint["reference_table"]
          reference_columns = constraint[:reference_columns] || constraint["reference_columns"] || ["id"]
          options = {
            column: Array(columns).first.to_s,
            primary_key: Array(reference_columns).first.to_s,
            name: constraint[:name] || constraint["name"]
          }
          options[:on_delete] = (constraint[:on_delete] || constraint["on_delete"]).to_s if constraint[:on_delete] || constraint["on_delete"]
          options[:on_update] = (constraint[:on_update] || constraint["on_update"]).to_s if constraint[:on_update] || constraint["on_update"]
          ActiveRecord::ConnectionAdapters::ForeignKeyDefinition.new(table_name.to_s, reference_table.to_s, options)
        end
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
        sql << if default.nil?
          " DROP DEFAULT"
        else
          " SET DEFAULT #{quote_default(default)}"
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
        schema = +""
        tables.each do |table|
          table_columns = columns(table)
          primary_key_name = if embedded?
            @connection.engine.table_columns(table).find(&:primary_key?)&.name
          else
            primary_key(table)
          end
          primary_key = table_columns.find { |column| column.name.to_s == primary_key_name.to_s } if primary_key_name
          automatic_id = primary_key && primary_key_name.to_s == "id" && primary_key.type.to_sym == :integer
          table_options = automatic_id ? "" : ", id: false"
          schema << "create_table \"#{table}\"#{table_options} do |t|\n"
          table_columns.each do |col|
            next if automatic_id && primary_key && col.name.to_s == primary_key.name.to_s

            type = RubyDB::Rails::Type.to_rails(col.type)
            schema << "  t.#{type} \"#{col.name}\""
            schema << ", primary_key: true" if primary_key && col.name.to_s == primary_key.name.to_s
            schema << ", default: #{schema_literal(col.default, col.type)}" unless col.default.nil?
            schema << ", null: false" unless col.null
            schema << "\n"
          end
          schema << "end\n\n"

          indexes(table).each do |index|
            schema << "add_index \"#{table}\", #{index.columns.map(&:to_s).inspect}"
            schema << ", unique: true" if index.unique
            schema << ", name: #{index.name.to_s.inspect}\n"
          end
          schema << "\n" if indexes(table).any?
        end
        schema
      end

      def schema_literal(value, type = nil)
        if type.to_sym == :boolean && value.is_a?(String) && %w[true false].include?(value.downcase)
          return value.downcase
        end

        case value
        when true then "true"
        when false then "false"
        when Numeric then value.to_s
        else value.to_s.inspect
        end
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

      attr_reader :query_cache_enabled

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
        false
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
            column.has_default? ? rails_default_value(column.default) : nil,
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

      # ActiveRecord's generic Column deduplication is string-oriented. RubyDB
      # persists typed defaults, so serialize scalar defaults at this boundary
      # and let ActiveRecord cast them through the column type map.
      def rails_default_value(value)
        # RubyDB exposes SQL defaults as AST literals. ActiveRecord expects
        # the scalar payload when it builds its Column metadata; calling
        # `to_s` on the wrapper would leak the Ruby object inspection into
        # newly instantiated records.
        value = value.value if value.respond_to?(:value) && !value.is_a?(String)
        value.is_a?(String) ? value : value.to_s
      end

      def sql_for_execution(sql)
        sql = sql.to_sql if sql.respond_to?(:to_sql)
        sql
      end

      def active_record_result(result)
        rows = result.to_a
        columns = if rows.first.respond_to?(:keys)
          rows.first.keys.map(&:to_s)
        else
          result.columns.map do |column|
            column.is_a?(Hash) ? (column[:name] || column["name"] || column) : column
          end.map(&:to_s)
        end
        values = rows.map do |row|
          columns.map do |column|
            if row.respond_to?(:key?) && row.key?(column)
              row[column]
            elsif row.respond_to?(:key?) && row.key?(column.to_sym)
              row[column.to_sym]
            end
          end
        end
        ActiveRecord::Result.new(columns, values)
      end

      # ActiveRecord normally supplies QueryAttribute objects, but migration
      # and schema code can also pass raw values or two-element bind pairs.
      # Normalize all supported forms at the adapter boundary.
      def bind_values(binds)
        binds.map do |bind|
          value = if bind.respond_to?(:value_for_database)
            bind.value_for_database
          elsif bind.respond_to?(:value)
            bind.value
          elsif bind.is_a?(Array) && bind.length == 2
            bind.last
          else
            bind
          end
          value.respond_to?(:value_for_database) ? value.value_for_database : value
        end
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
        end
      end

      def log(sql, name = nil, &block)
        start_time = Time.now
        result = block.call
        elapsed_ms = (Time.now - start_time) * 1000

        @logger&.debug "  #{name || "SQL"} (#{elapsed_ms.round(2)}ms) #{sql}"

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

# Rails 7.2 introduced explicit adapter registration. Rails 7.1 loads custom
# adapters through the conventional `rubydb_connection` hook instead.
if ActiveRecord::ConnectionAdapters.respond_to?(:register)
  ActiveRecord::ConnectionAdapters.register("rubydb", "ActiveRecord::ConnectionAdapters::RubyDBAdapter")
else
  module ActiveRecord
    module ConnectionHandling
      def rubydb_adapter_class
        ConnectionAdapters::RubyDBAdapter
      end

      def rubydb_connection(config)
        rubydb_adapter_class.new(config)
      end
    end
  end
end
