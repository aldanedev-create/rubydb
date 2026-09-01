# frozen_string_literal: true

module RubyDB
  module Types
    # 16-bit signed integer
    class SmallInt < Type
      RANGE = (-32_768..32_767).freeze
      SIZE = 2

      def initialize
        super(:smallint, size: SIZE)
      end

      def serialize(value)
        validate(value)
        [value.to_i].pack("s>")  # Big-endian 16-bit signed
      end

      def deserialize(bytes)
        return nil if bytes.nil? || bytes.empty?
        bytes.unpack("s>").first
      end

      def validate(value)
        return true if value.nil?
        raise ConstraintError, "Invalid smallint: #{value}" unless value.is_a?(::Integer)
        raise ConstraintError, "SmallInt out of range: #{value}" unless RANGE.include?(value)
        true
      end

      def default
        0
      end
    end
  end
end