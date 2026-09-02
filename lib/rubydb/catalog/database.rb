# frozen_string_literal: true

module RubyDB
  module Catalog
    # Database - contains schemas, tables, sequences, views, triggers
    class Database
      attr_reader :name, :tables, :schemas, :sequences, :views, :triggers, :created_at, :modified_at

      def initialize(name)
        @name = name
        @tables = {}
        @schemas = { "public" => PublicSchema.new }
        @sequences = {}
        @views = {}
        @triggers = {}
        @created_at = Time.now
        @modified_at = Time.now
        @options = {}
      end

      # --- Table Methods ---

      def add_table(table)
        @tables[table.name] = table
        @modified_at = Time.now
        table
      end

      def drop_table(name)
        table = @tables.delete(name)
        @modified_at = Time.now
        table
      end

      def find_table(name)
        @tables[name]
      end

      def table_exists?(name)
        @tables.key?(name)
      end

      def tables
        @tables.values
      end

      def create_schema(name, if_not_exists: false, authorization: nil)
        if @schemas.key?(name)
          return if if_not_exists
          raise DatabaseError, "Schema '#{name}' already exists"
        end
        @schemas[name] = Schema.new(name, owner: authorization)
      end

      def drop_schema(name, if_exists: false, cascade: false)
        unless @schemas.key?(name)
          return if if_exists
          raise DatabaseError, "Schema '#{name}' does not exist"
        end
        schema = @schemas[name]
        if !cascade && schema.tables.any?
          raise DatabaseError, "Schema '#{name}' is not empty"
        end
        @schemas.delete(name)
      end

      def find_schema(name)
        @schemas[name]
      end

      # --- Sequence Methods ---

      def add_sequence(sequence)
        @sequences[sequence.name] = sequence
        @modified_at = Time.now
        sequence
      end

      def drop_sequence(name)
        sequence = @sequences.delete(name)
        @modified_at = Time.now
        sequence
      end

      def find_sequence(name)
        @sequences[name]
      end

      def sequence_exists?(name)
        @sequences.key?(name)
      end

      # --- View Methods ---

      def add_view(view)
        @views[view.name] = view
        @modified_at = Time.now
        view
      end

      def drop_view(name)
        view = @views.delete(name)
        @modified_at = Time.now
        view
      end

      def find_view(name)
        @views[name]
      end

      def view_exists?(name)
        @views.key?(name)
      end

      # --- Trigger Methods ---

      def add_trigger(trigger)
        @triggers[trigger.name] = trigger
        @modified_at = Time.now
        trigger
      end

      def drop_trigger(name)
        trigger = @triggers.delete(name)
        @modified_at = Time.now
        trigger
      end

      def find_trigger(name)
        @triggers[name]
      end

      def trigger_exists?(name)
        @triggers.key?(name)
      end

      # --- Serialization ---

      def serialize
        {
          name: @name,
          created_at: @created_at.iso8601,
          modified_at: @modified_at.iso8601,
          tables: @tables.transform_values(&:serialize),
          schemas: @schemas.transform_values(&:serialize),
          sequences: @sequences.transform_values(&:serialize),
          views: @views.transform_values(&:serialize),
          triggers: @triggers.transform_values(&:serialize),
          options: @options
        }
      end

      def self.deserialize(data)
        db = new(data[:name])
        data[:schemas]&.each { |name, schema_data| db.schemas[name.to_s] = Schema.deserialize(schema_data) }
        db.send(:created_at=, Time.parse(data[:created_at])) if data[:created_at]
        db.send(:modified_at=, Time.parse(data[:modified_at])) if data[:modified_at]

        data[:tables]&.each do |name, table_data|
          db.instance_variable_get(:@tables)[name.to_s] = Table.deserialize(table_data)
        end

        data[:sequences]&.each do |name, seq_data|
          db.sequences[name.to_s] = Sequence.deserialize(seq_data)
        end

        data[:views]&.each do |name, view_data|
          db.views[name.to_s] = View.deserialize(view_data)
        end

        data[:triggers]&.each do |name, trigger_data|
          db.triggers[name.to_s] = Trigger.deserialize(trigger_data)
        end

        db.send(:options=, data[:options]) if data[:options]
        db
      end

      protected

      attr_writer :created_at, :modified_at, :options
    end
  end
end
