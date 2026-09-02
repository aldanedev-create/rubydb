# frozen_string_literal: true

module RubyDB
  module Catalog
    # Index - represents a database index
    class Index
      attr_reader :name, :table_name, :columns, :unique, :options
      attr_accessor :size

      def initialize(name, table_name, columns, unique: false, **options)
        @name = name
        @table_name = table_name
        @columns = columns.is_a?(Array) ? columns : [columns]
        @unique = unique
        @options = options
        @size = 0
        @created_at = Time.now
        @modified_at = Time.now
        @type = options[:type] || :btree
        @where = options[:where]
        @include_columns = options[:include] || []
        @fills = options[:fills] || []
      end

      def btree?
        @type == :btree
      end

      def hash?
        @type == :hash
      end

      def gin?
        @type == :gin
      end

      def gist?
        @type == :gist
      end

      def partial?
        !@where.nil?
      end

      def covering?
        @include_columns.any?
      end

      def to_s
        "#{@name} ON #{@table_name}(#{@columns.join(", ")})"
      end

      def inspect
        "#<Index name=#{@name} table=#{@table_name} columns=[#{@columns.join(", ")}] unique=#{@unique}>"
      end

      # --- Serialization ---

      def serialize
        {
          name: @name,
          table_name: @table_name,
          columns: @columns,
          unique: @unique,
          type: @type,
          where: @where,
          include: @include_columns,
          fills: @fills,
          size: @size,
          created_at: @created_at.iso8601,
          modified_at: @modified_at.iso8601
        }
      end

      def self.deserialize(data)
        index = new(
          data[:name],
          data[:table_name],
          data[:columns],
          unique: data[:unique] || false,
          type: data[:type] || :btree,
          where: data[:where],
          include: data[:include] || [],
          fills: data[:fills] || []
        )
        index.size = data[:size] if data[:size]
        index.send(:created_at=, Time.parse(data[:created_at])) if data[:created_at]
        index.send(:modified_at=, Time.parse(data[:modified_at])) if data[:modified_at]
        index
      end

      protected

      attr_writer :created_at, :modified_at
    end
  end
end
