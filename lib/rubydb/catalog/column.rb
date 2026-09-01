# frozen_string_literal: true

module RubyDB
  module Catalog
    # Column - represents a table column
    class Column
      attr_reader :name, :type, :options
      attr_accessor :default, :nullable, :position

      def initialize(name, type, **options)
        @name = name
        @type = type
        @options = options
        @default = options[:default]
        @nullable = options.fetch(:null, true)
        @position = options[:position]
        @primary_key = options[:primary_key] || false
        @unique = options[:unique] || false
        @precision = options[:precision]
        @scale = options[:scale]
        @limit = options[:limit]
        @created_at = Time.now
        @modified_at = Time.now
      end

      def primary_key?
        @primary_key
      end

      def unique?
        @unique
      end

      def nullable?
        @nullable
      end

      def has_default?
        !@default.nil?
      end

      def type_class
        case @type
        when Symbol
          @type
        when Hash
          @type[:type]
        else
          @type
        end
      end

      def type_params
        case @type
        when Hash
          @type.reject { |k| k == :type }
        else
          {}
        end
      end

      def to_s
        "#{@name} #{@type.to_s.upcase}"
      end

      def inspect
        "#<Column name=#{@name} type=#{@type} primary_key=#{@primary_key} nullable=#{@nullable}>"
      end

      # --- Serialization ---

      def serialize
        {
          name: @name,
          type: @type,
          default: @default,
          nullable: @nullable,
          position: @position,
          primary_key: @primary_key,
          unique: @unique,
          precision: @precision,
          scale: @scale,
          limit: @limit,
          created_at: @created_at.iso8601,
          modified_at: @modified_at.iso8601
        }
      end

      def self.deserialize(data)
        column = new(
          data[:name],
          data[:type],
          default: data[:default],
          null: data[:nullable],
          position: data[:position],
          primary_key: data[:primary_key] || false,
          unique: data[:unique] || false,
          precision: data[:precision],
          scale: data[:scale],
          limit: data[:limit]
        )
        column.created_at = Time.parse(data[:created_at]) if data[:created_at]
        column.modified_at = Time.parse(data[:modified_at]) if data[:modified_at]
        column
      end

      protected

      attr_writer :created_at, :modified_at
    end
  end
end