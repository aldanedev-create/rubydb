# frozen_string_literal: true

module RubyDB
  module Types
    # Base class for all data types
    class Type
      attr_reader :name, :size, :precision, :scale

      def initialize(name, size: nil, precision: nil, scale: nil)
        @name = name
        @size = size
        @precision = precision
        @scale = scale
      end

      def serialize(value)
        raise NotImplementedError, "#{self.class} must implement #serialize"
      end

      def deserialize(bytes)
        raise NotImplementedError, "#{self.class} must implement #deserialize"
      end

      def validate(value)
        raise NotImplementedError, "#{self.class} must implement #validate"
      end

      def compare(a, b)
        return 0 if a == b
        return -1 if a < b
        1
      end

      def default
        nil
      end

      def sql_type
        @name.to_s.upcase
      end

      def storage_size
        @size
      end

      def to_s
        sql_type
      end

      def inspect
        "#<#{self.class} name=#{@name} size=#{@size}>"
      end
    end

    # Type registry for looking up types by name
    class TypeRegistry
      @types = {}

      class << self
        attr_reader :types

        def register(name, type_class)
          @types[name.to_sym] = type_class
        end

        def lookup(name, **kwargs)
          type_class = @types[name.to_sym]
          return type_class.new(**kwargs) if type_class
          raise ConfigurationError, "Unknown type: #{name}"
        end

        def reset
          @types = {}
        end
      end

      # Register all built-in types
      register(:integer, Integer)
      register(:bigint, BigInt)
      register(:smallint, SmallInt)
      register(:float, Float)
      register(:decimal, Decimal)
      register(:boolean, Boolean)
      register(:text, Text)
      register(:varchar, Varchar)
      register(:blob, Blob)
      register(:date, Date)
      register(:time, Time)
      register(:timestamp, Timestamp)
      register(:json, Json)
      register(:uuid, UUID)
      register(:null, Null)
    end
  end
end