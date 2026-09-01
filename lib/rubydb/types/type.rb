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

        def register(name, type_class = nil)
          klass = type_class || resolve(name)
          return if klass.nil?

          @types[name.to_sym] = klass
        end

        def lookup(name, **kwargs)
          type_class = @types[name.to_sym] || resolve(name)
          return type_class.new(**kwargs) if type_class

          raise ConfigurationError, "Unknown type: #{name}"
        end

        def reset
          @types = {}
        end

        private

        def resolve(name)
          name = name.to_sym
          const_name = case name
                       when :bigint then "BigInt"
                       when :smallint then "SmallInt"
                       when :float then "Float"
                       when :decimal then "Decimal"
                       when :boolean then "Boolean"
                       when :text then "Text"
                       when :varchar then "Varchar"
                       when :blob then "Blob"
                       when :date then "Date"
                       when :time then "Time"
                       when :timestamp then "Timestamp"
                       when :json then "Json"
                       when :uuid then "UUID"
                       when :null then "Null"
                       when :integer then "Integer"
                       else name.to_s.split("_").map { |part| part.capitalize }.join
                       end

          klass = RubyDB::Types.const_get(const_name)
          @types[name] = klass
          klass
        rescue NameError
          nil
        end
      end
    end
  end
end