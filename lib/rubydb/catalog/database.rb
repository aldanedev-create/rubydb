# frozen_string_literal: true

module RubyDB
  module Catalog
    # Database - contains schemas, tables, sequences, views, triggers
    class Database
      attr_reader :name, :tables, :sequences, :views, :triggers, :created_at, :modified_at

      def initialize(name)
        @name = name
        @tables = {}
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
          sequences: @sequences.transform_values(&:serialize),
          views: @views.transform_values(&:serialize),
          triggers: @triggers.transform_values(&:serialize),
          options: @options
        }
      end

      def self.deserialize(data)
        db = new(data[:name])
        db.created_at = Time.parse(data[:created_at]) if data[:created_at]
        db.modified_at = Time.parse(data[:modified_at]) if data[:modified_at]

        data[:tables]&.each do |name, table_data|
          db.tables[name] = Table.deserialize(table_data)
        end

        data[:sequences]&.each do |name, seq_data|
          db.sequences[name] = Sequence.deserialize(seq_data)
        end

        data[:views]&.each do |name, view_data|
          db.views[name] = View.deserialize(view_data)
        end

        data[:triggers]&.each do |name, trigger_data|
          db.triggers[name] = Trigger.deserialize(trigger_data)
        end

        db.options = data[:options] if data[:options]
        db
      end

      protected

      attr_writer :created_at, :modified_at, :options
    end
  end
end