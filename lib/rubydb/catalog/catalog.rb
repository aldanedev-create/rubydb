# frozen_string_literal: true

require "json"

module RubyDB
  module Catalog
    # Main catalog - manages all database metadata
    class Catalog
      attr_reader :databases, :current_database, :tables, :system_catalog

      def initialize
        @databases = {}
        @current_database = nil
        @tables = {}
        @sequences = {}
        @views = {}
        @triggers = {}
        @system_catalog = SystemCatalog.new(self)
        @version = 1
        @created_at = Time.now
        @modified_at = Time.now
      end

      # --- Database Management ---

      def create_database(name, if_not_exists: false)
        if @databases.key?(name)
          return if if_not_exists
          raise DatabaseError, "Database '#{name}' already exists"
        end

        db = Database.new(name)
        @databases[name] = db
        @current_database = db if @databases.size == 1
        @modified_at = Time.now
        db
      end

      def drop_database(name, if_exists: false)
        unless @databases.key?(name)
          return if if_exists
          raise DatabaseError, "Database '#{name}' does not exist"
        end

        @databases.delete(name)
        @current_database = @databases.values.first if @current_database&.name == name
        @modified_at = Time.now
        true
      end

      def find_database(name)
        @databases[name]
      end

      def create_schema(name, if_not_exists: false, authorization: nil)
        raise DatabaseError, "No database selected" unless @current_database
        schema = @current_database.create_schema(name, if_not_exists: if_not_exists, authorization: authorization)
        @modified_at = Time.now
        schema
      end

      def drop_schema(name, if_exists: false, cascade: false)
        raise DatabaseError, "No database selected" unless @current_database
        result = @current_database.drop_schema(name, if_exists: if_exists, cascade: cascade)
        @modified_at = Time.now
        result
      end

      def find_schema(name)
        @current_database&.find_schema(name)
      end

      def use_database(name)
        db = @databases[name]
        raise DatabaseError, "Database '#{name}' does not exist" unless db
        @current_database = db
        @modified_at = Time.now
        db
      end

      def current_database_name
        @current_database&.name
      end

      # --- Table Management ---

      def create_table(name, &block)
        raise DatabaseError, "No database selected" unless @current_database

        if @current_database.table_exists?(name)
          raise DatabaseError, "Table '#{name}' already exists in database '#{@current_database.name}'"
        end

        table = Table.new(name, @current_database)
        @current_database.add_table(table)

        # Execute block to define columns
        if block_given?
          builder = TableBuilder.new(table)
          yield builder
        end

        @tables[name] = table
        @modified_at = Time.now
        table
      end

      def drop_table(name, if_exists: false)
        raise DatabaseError, "No database selected" unless @current_database

        unless @current_database.table_exists?(name)
          return if if_exists
          raise DatabaseError, "Table '#{name}' does not exist"
        end

        table = @current_database.drop_table(name)
        @tables.delete(name)
        @modified_at = Time.now
        table
      end

      def find_table(name)
        return nil unless @current_database
        @current_database.find_table(name)
      end

      def tables
        return [] unless @current_database
        @current_database.tables.values
      end

      def table_exists?(name)
        return false unless @current_database
        @current_database.table_exists?(name)
      end

      # --- Sequence Management ---

      def create_sequence(name, options = {})
        raise DatabaseError, "No database selected" unless @current_database

        if @current_database.sequence_exists?(name)
          raise DatabaseError, "Sequence '#{name}' already exists"
        end

        sequence = Sequence.new(name, options)
        @current_database.add_sequence(sequence)
        @sequences[name] = sequence
        @modified_at = Time.now
        sequence
      end

      def drop_sequence(name, if_exists: false)
        raise DatabaseError, "No database selected" unless @current_database

        unless @current_database.sequence_exists?(name)
          return if if_exists
          raise DatabaseError, "Sequence '#{name}' does not exist"
        end

        sequence = @current_database.drop_sequence(name)
        @sequences.delete(name)
        @modified_at = Time.now
        sequence
      end

      def find_sequence(name)
        return nil unless @current_database
        @current_database.find_sequence(name)
      end

      def next_value_for_sequence(name)
        seq = find_sequence(name)
        raise DatabaseError, "Sequence '#{name}' does not exist" unless seq
        seq.next_value
      end

      # --- View Management ---

      def create_view(name, query, if_not_exists: false)
        raise DatabaseError, "No database selected" unless @current_database

        if @current_database.view_exists?(name)
          return @current_database.find_view(name) if if_not_exists
          raise DatabaseError, "View '#{name}' already exists"
        end

        view = View.new(name, query)
        @current_database.add_view(view)
        @views[name] = view
        @modified_at = Time.now
        view
      end

      def drop_view(name, if_exists: false)
        raise DatabaseError, "No database selected" unless @current_database

        unless @current_database.view_exists?(name)
          return if if_exists
          raise DatabaseError, "View '#{name}' does not exist"
        end

        view = @current_database.drop_view(name)
        @views.delete(name)
        @modified_at = Time.now
        view
      end

      def find_view(name)
        return nil unless @current_database
        @current_database.find_view(name)
      end

      # --- Trigger Management ---

      def create_trigger(name, event, table_name, definition, **options)
        raise DatabaseError, "No database selected" unless @current_database

        if @current_database.trigger_exists?(name)
          raise DatabaseError, "Trigger '#{name}' already exists"
        end

        trigger = Trigger.new(name, event, table_name, definition, options)
        @current_database.add_trigger(trigger)
        @triggers[name] = trigger
        @modified_at = Time.now
        trigger
      end

      def drop_trigger(name, if_exists: false)
        raise DatabaseError, "No database selected" unless @current_database

        unless @current_database.trigger_exists?(name)
          return if if_exists
          raise DatabaseError, "Trigger '#{name}' does not exist"
        end

        trigger = @current_database.drop_trigger(name)
        @triggers.delete(name)
        @modified_at = Time.now
        trigger
      end

      def find_trigger(name)
        return nil unless @current_database
        @current_database.find_trigger(name)
      end

      # --- Serialization ---

      def serialize
        data = {
          version: @version,
          created_at: @created_at.iso8601,
          modified_at: @modified_at.iso8601,
          current_database: @current_database&.name,
          databases: @databases.transform_values(&:serialize),
          system_catalog: @system_catalog.serialize
        }
        JSON.generate(data)
      end

      def self.deserialize(json_data)
        data = JSON.parse(json_data, symbolize_names: true)
        catalog = new

        data[:databases].each do |name, db_data|
          db = Database.deserialize(db_data)
          catalog.databases[name.to_s] = db
        end

        if data[:current_database]
          current = catalog.databases[data[:current_database]] || catalog.databases[data[:current_database].to_sym]
          catalog.send(:current_database=, current)
        end

        # Rebuild indexes
        catalog.databases.each do |_name, db|
          db.tables.each do |table|
            catalog.instance_variable_get(:@tables)[table.name] = table
            table.columns.each do |col|
              # Build indexes for columns
              if col.primary_key?
                index = Index.new("primary_#{table.name}", table.name, [col.name], unique: true)
                table.add_index(index)
              end
              if col.unique?
                index = Index.new("unique_#{table.name}_#{col.name}", table.name, [col.name], unique: true)
                table.add_index(index)
              end
            end
          end
        end

        catalog
      end

      protected

      attr_writer :current_database
    end

    # Builder for creating tables with a DSL
    class TableBuilder
      attr_reader :table

      def initialize(table)
        @table = table
      end

      def column(name, type, **options)
        @table.add_column(Column.new(name, type, **options))
      end

      def integer(name, **options)
        column(name, :integer, **options)
      end

      def bigint(name, **options)
        column(name, :bigint, **options)
      end

      def smallint(name, **options)
        column(name, :smallint, **options)
      end

      def float(name, **options)
        column(name, :float, **options)
      end

      def decimal(name, precision: 10, scale: 2, **options)
        column(name, :decimal, precision: precision, scale: scale, **options)
      end

      def boolean(name, **options)
        column(name, :boolean, **options)
      end

      def text(name, **options)
        column(name, :text, **options)
      end

      def varchar(name, limit: 255, **options)
        column(name, :varchar, limit: limit, **options)
      end

      def blob(name, **options)
        column(name, :blob, **options)
      end

      def date(name, **options)
        column(name, :date, **options)
      end

      def time(name, **options)
        column(name, :time, **options)
      end

      def timestamp(name, **options)
        column(name, :timestamp, **options)
      end

      def json(name, **options)
        column(name, :json, **options)
      end

      def uuid(name, **options)
        column(name, :uuid, **options)
      end

      def primary_key(name = :id, **options)
        column(name, :integer, primary_key: true, **options)
      end

      def timestamps
        timestamp(:created_at, default: "CURRENT_TIMESTAMP")
        timestamp(:updated_at, default: "CURRENT_TIMESTAMP")
      end

      def index(name, **options)
        @table.add_index(Index.new(name, @table.name, **options))
      end

      def foreign_key(column, ref_table, ref_column = :id, **options)
        @table.add_constraint(
          ForeignKeyConstraint.new(column, ref_table, ref_column, **options)
        )
      end
    end
  end
end
