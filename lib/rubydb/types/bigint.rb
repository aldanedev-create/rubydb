# frozen_string_literal: true

module RubyDB
  module Types
    # 64-bit signed integer
    class BigInt < Type
      RANGE = (-9_223_372_036_854_775_808..9_223_372_036_854_775_807).freeze
      SIZE = 8

      def initialize
        super(:bigint, size: SIZE)
      end

      def serialize(value)
        validate(value)
        [value.to_i].pack("q>")  # Big-endian 64-bit signed
      end

      def deserialize(bytes)
        return nil if bytes.nil? || bytes.empty?
        bytes.unpack("q>").first
      end

      def validate(value)
        return true if value.nil?
        raise ConstraintError, "Invalid bigint: #{value}" unless value.is_a?(::Integer)
        raise ConstraintError, "BigInt out of range: #{value}" unless RANGE.include?(value)
        true
      end

      def default
        0
      end
    end
  end
end