# frozen_string_literal: true

module RubyDB
  module Catalog
    # Schema - contains tables, views, etc. (PostgreSQL-style schema)
    class Schema
      attr_reader :name, :tables, :views, :sequences, :owner

      def initialize(name, owner: nil)
        @name = name
        @owner = owner
        @tables = {}
        @views = {}
        @sequences = {}
        @created_at = Time.now
      end

      def add_table(table)
        @tables[table.name] = table
        table
      end

      def drop_table(name)
        @tables.delete(name)
      end

      def find_table(name)
        @tables[name]
      end

      def table_exists?(name)
        @tables.key?(name)
      end

      def add_view(view)
        @views[view.name] = view
        view
      end

      def drop_view(name)
        @views.delete(name)
      end

      def find_view(name)
        @views[name]
      end

      def add_sequence(sequence)
        @sequences[sequence.name] = sequence
        sequence
      end

      def drop_sequence(name)
        @sequences.delete(name)
      end

      def find_sequence(name)
        @sequences[name]
      end

      def serialize
        {
          name: @name,
          owner: @owner,
          created_at: @created_at.iso8601,
          tables: @tables.transform_values(&:serialize),
          views: @views.transform_values(&:serialize),
          sequences: @sequences.transform_values(&:serialize)
        }
      end

      def self.deserialize(data)
        schema = new(data[:name], owner: data[:owner])
        schema.created_at = Time.parse(data[:created_at]) if data[:created_at]

        data[:tables]&.each do |name, table_data|
          schema.tables[name] = Table.deserialize(table_data)
        end

        data[:views]&.each do |name, view_data|
          schema.views[name] = View.deserialize(view_data)
        end

        data[:sequences]&.each do |name, seq_data|
          schema.sequences[name] = Sequence.deserialize(seq_data)
        end

        schema
      end

      protected

      attr_writer :created_at
    end

    # Default schemas
    class PublicSchema < Schema
      def initialize
        super("public")
      end
    end
  end
end