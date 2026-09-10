# frozen_string_literal: true

module RubyDB
  module Rails
    # SchemaStatements - Schema statement methods for Rails
    module SchemaStatements
      # Collects a Rails-style create_table block into executable SQL.
      class TableDefinition
        TYPE_METHODS = %i[bigint binary boolean date datetime decimal float integer json smallint string text time timestamp uuid].freeze
        attr_reader :columns, :constraints

        def initialize(adapter, table_name, options = {})
          @adapter = adapter
          @table_name = table_name
          @options = options
          @columns = []
          @constraints = []
        end

        def column(name, type, options = {})
          @columns << RubyDB::Catalog::Column.new(name, type, **options)
          self
        end

        def timestamps(options = {})
          column(:created_at, :timestamp, options)
          column(:updated_at, :timestamp, options)
        end

        def primary_key(name = :id, type = :integer, options = {})
          column(name, type, options.merge(primary_key: true, null: false))
        end

        # Support Rails' common `t.references :repository, foreign_key: true`
        # shorthand while keeping the generated SQL within RubyDB's schema
        # contract. Index creation remains an explicit `add_index` operation.
        def references(name, options = {})
          reference_name = name.to_s
          column_name = options[:column] || "#{reference_name}_id"
          column_options = options.slice(:null, :default, :limit, :precision, :scale)
          column(column_name, options[:type] || :integer, column_options)

          return self unless options[:foreign_key]

          reference_table = options[:to_table] || pluralize_reference(reference_name)
          @constraints << RubyDB::Constraints::ForeignKeyConstraint.new(
            @table_name,
            column_name,
            reference_table,
            options[:primary_key] || :id,
            options.slice(:name, :on_delete, :on_update)
          )
          self
        end

        def pluralize_reference(name)
          return name if name.end_with?("s")
          return "#{name[0...-1]}ies" if name.end_with?("y")

          "#{name}s"
        end
        private :pluralize_reference

        def method_missing(method, *args, &block)
          if TYPE_METHODS.include?(method)
            name = args.shift
            options = args.shift || {}
            return column(name, method, options)
          end
          super
        end

        def respond_to_missing?(method, include_private = false)
          TYPE_METHODS.include?(method) || method == :references || super
        end
      end

      def create_table(table_name, options = {})
        columns = []
        constraints = []

        # Rails creates an integer primary key unless a migration explicitly
        # requests id: false. Keep the same default for both the standalone
        # RubyDB adapter and ActiveRecord's migration DSL.
        unless options[:id] == false
          primary_key_name = options[:primary_key] || :id
          primary_key_type = options[:id].is_a?(Symbol) ? options[:id] : :integer
          columns << RubyDB::Catalog::Column.new(primary_key_name, primary_key_type, primary_key: true, null: false)
        end

        if block_given?
          table_definition = TableDefinition.new(self, table_name, options)
          yield table_definition
          columns.concat(table_definition.columns)
          constraints = table_definition.constraints
        end

        sql = build_create_table_sql(table_name, columns, constraints, options)
        execute(sql)
      end

      def drop_table(table_name, options = {})
        sql = "DROP TABLE"
        sql << " IF EXISTS" if options[:if_exists]
        sql << " #{quote_table_name(table_name)}"
        sql << " CASCADE" if options[:cascade]
        execute(sql)
      end

      def add_column(table_name, column_name, type, options = {})
        sql = "ALTER TABLE #{quote_table_name(table_name)}"
        sql << " ADD COLUMN #{quote_column_name(column_name)} #{type_to_sql(type, options)}"

        if options[:null] == false
          sql << " NOT NULL"
        end

        if options.key?(:default)
          sql << " DEFAULT #{quote_default(options[:default])}"
        end

        if options[:primary_key]
          sql << " PRIMARY KEY"
        end

        execute(sql)
      end

      def remove_column(table_name, column_name, type = nil, options = {})
        sql = "ALTER TABLE #{quote_table_name(table_name)}"
        sql << " DROP COLUMN #{quote_column_name(column_name)}"
        sql << " CASCADE" if options[:cascade]
        execute(sql)
      end

      def change_column(table_name, column_name, type, options = {})
        sql = "ALTER TABLE #{quote_table_name(table_name)}"
        sql << " ALTER COLUMN #{quote_column_name(column_name)}"
        sql << " TYPE #{type_to_sql(type, options)}"
        execute(sql)

        if options[:null] == false
          sql = "ALTER TABLE #{quote_table_name(table_name)}"
          sql << " ALTER COLUMN #{quote_column_name(column_name)} SET NOT NULL"
          execute(sql)
        elsif options[:null] == true
          sql = "ALTER TABLE #{quote_table_name(table_name)}"
          sql << " ALTER COLUMN #{quote_column_name(column_name)} DROP NOT NULL"
          execute(sql)
        end

        return unless options.key?(:default)

        sql = "ALTER TABLE #{quote_table_name(table_name)} ALTER COLUMN #{quote_column_name(column_name)}"
        sql << if options[:default].nil?
          " DROP DEFAULT"
        else
          " SET DEFAULT #{quote_default(options[:default])}"
        end
        execute(sql)
      end

      def rename_column(table_name, column_name, new_column_name)
        sql = "ALTER TABLE #{quote_table_name(table_name)}"
        sql << " RENAME COLUMN #{quote_column_name(column_name)}"
        sql << " TO #{quote_column_name(new_column_name)}"
        execute(sql)
      end

      def add_index(table_name, column_name, options = {})
        index_name = options[:name] || "idx_#{table_name}_#{Array(column_name).join("_")}"
        sql = +"CREATE"
        sql << " UNIQUE" if options[:unique]
        sql << " INDEX #{quote_column_name(index_name)}"
        sql << " ON #{quote_table_name(table_name)}"
        sql << " (#{Array(column_name).map { |c| quote_column_name(c) }.join(", ")})"
        execute(sql)
      end

      def remove_index(table_name, options = {})
        index_name = options[:name]
        if index_name.nil?
          column_name = options[:column] || options[:columns]
          index_name = "idx_#{table_name}_#{Array(column_name).join("_")}"
        end

        sql = "DROP INDEX #{quote_column_name(index_name)}"
        sql << " ON #{quote_table_name(table_name)}"
        execute(sql)
      end

      def add_foreign_key(from_table, to_table, options = {})
        fk_name = options[:name] || "fk_#{from_table}_to_#{to_table}"
        sql = "ALTER TABLE #{quote_table_name(from_table)}"
        sql << " ADD CONSTRAINT #{quote_column_name(fk_name)}"
        column = options[:column] || "#{to_table.to_s.sub(/s\z/, "")}_id"
        sql << " FOREIGN KEY (#{quote_column_name(column)})"
        sql << " REFERENCES #{quote_table_name(to_table)}"
        sql << " (#{quote_column_name(options[:primary_key] || :id)})"
        execute(sql)
      end

      def remove_foreign_key(from_table, options = {})
        fk_name = options[:name] || "fk_#{from_table}_to_#{options[:to_table]}"
        sql = "ALTER TABLE #{quote_table_name(from_table)}"
        sql << " DROP CONSTRAINT #{quote_column_name(fk_name)}"
        execute(sql)
      end

      def add_timestamps(table_name, options = {})
        add_column(table_name, :created_at, :timestamp, options)
        add_column(table_name, :updated_at, :timestamp, options)
      end

      def remove_timestamps(table_name, options = {})
        remove_column(table_name, :updated_at, nil, options)
        remove_column(table_name, :created_at, nil, options)
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
          " SET DEFAULT #{quote(default)}"
        end
        execute(sql)
      end

      private

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

      def build_create_table_sql(table_name, columns, constraints, options)
        sql = +"CREATE TABLE"
        sql << " IF NOT EXISTS" if options[:if_not_exists]
        sql << " #{quote_table_name(table_name)} ("

        col_defs = columns.map do |col|
          definition = "#{quote_column_name(col.name)} #{type_to_sql(col.type, col.options)}"
          definition << " PRIMARY KEY" if col.options[:primary_key]
          definition << " NOT NULL" if col.options[:null] == false
          definition << " DEFAULT #{quote(col.options[:default])}" if col.options.key?(:default)
          definition
        end

        constraints.each do |constraint|
          col_defs << constraint.to_sql
        end

        sql << col_defs.join(", ")
        sql << ")"
        sql
      end

      def quote(value)
        case value
        when String
          "'#{value.gsub("'", "''")}'"
        when Numeric
          value.to_s
        when TrueClass
          "TRUE"
        when FalseClass
          "FALSE"
        when nil
          "NULL"
        when Date, Time, DateTime
          "'#{value.iso8601}'"
        else
          "'#{value.to_s.gsub("'", "''")}'"
        end
      end

      def quote_table_name(name)
        "\"#{name}\""
      end

      def quote_column_name(name)
        "\"#{name}\""
      end

      def quote_default(value)
        quote(value)
      end
    end
  end
end
