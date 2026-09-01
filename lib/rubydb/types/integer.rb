# frozen_string_literal: true

module RubyDB
  module Types
    # 32-bit signed integer
    class Integer < Type
      RANGE = (-2_147_483_648..2_147_483_647).freeze
      SIZE = 4

      def initialize
        super(:integer, size: SIZE)
      end

      def serialize(value)
        validate(value)
        [value.to_i].pack("l>")  # Big-endian 32-bit signed
      end

      def deserialize(bytes)
        return nil if bytes.nil? || bytes.empty?
        bytes.unpack("l>").first
      end

      def validate(value)
        return true if value.nil?
        raise ConstraintError, "Invalid integer: #{value}" unless value.is_a?(::Integer)
        raise ConstraintError, "Integer out of range: #{value}" unless RANGE.include?(value)
        true
      end

      def default
        0
      end
    end
  end
end