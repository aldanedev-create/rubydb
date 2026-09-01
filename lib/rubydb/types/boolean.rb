# frozen_string_literal: true

module RubyDB
  module Types
    # Boolean type (true/false)
    class Boolean < Type
      SIZE = 1

      def initialize
        super(:boolean, size: SIZE)
      end

      def serialize(value)
        validate(value)
        value ? "\x01".b : "\x00".b
      end

      def deserialize(bytes)
        return nil if bytes.nil? || bytes.empty?
        bytes.unpack("C").first == 1
      end

      def validate(value)
        return true if value.nil?
        raise ConstraintError, "Invalid boolean: #{value}" unless [true, false].include?(value)
        true
      end

      def default
        false
      end
    end
  end
end