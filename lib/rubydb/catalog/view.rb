# frozen_string_literal: true

module RubyDB
  module Catalog
    # View - represents a database view (virtual table)
    class View
      attr_reader :name, :query, :columns
      attr_accessor :materialized

      def initialize(name, query, materialized: false)
        @name = name
        @query = query
        @columns = []
        @materialized = materialized
        @created_at = Time.now
        @modified_at = Time.now
      end

      def add_column(name, type)
        @columns << { name: name, type: type }
        @modified_at = Time.now
      end

      def column_names
        @columns.map { |c| c[:name] }
      end

      def to_s
        if @materialized
          "MATERIALIZED VIEW #{@name}"
        else
          "VIEW #{@name}"
        end
      end

      def inspect
        "#<View name=#{@name} materialized=#{@materialized} columns=#{@columns.size}>"
      end

      # --- Serialization ---

      def serialize
        {
          name: @name,
          query: @query,
          columns: @columns,
          materialized: @materialized,
          created_at: @created_at.iso8601,
          modified_at: @modified_at.iso8601
        }
      end

      def self.deserialize(data)
        view = new(data[:name], data[:query], materialized: data[:materialized] || false)
        view.columns = data[:columns] if data[:columns]
        view.created_at = Time.parse(data[:created_at]) if data[:created_at]
        view.modified_at = Time.parse(data[:modified_at]) if data[:modified_at]
        view
      end

      protected

      attr_writer :created_at, :modified_at, :columns
    end
  end
end