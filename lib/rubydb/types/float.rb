# frozen_string_literal: true

module RubyDB
  module Types
    # 64-bit floating point (Double precision)
    class Float < Type
      SIZE = 8

      def initialize
        super(:float, size: SIZE)
      end

      def serialize(value)
        validate(value)
        [value.to_f].pack("E")  # Big-endian double
      end

      def deserialize(bytes)
        return nil if bytes.nil? || bytes.empty?
        bytes.unpack("E").first
      end

      def validate(value)
        return true if value.nil?
        raise ConstraintError, "Invalid float: #{value}" unless value.is_a?(::Numeric)
        true
      end

      def default
        0.0
      end
    end
  end
end