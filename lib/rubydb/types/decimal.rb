# frozen_string_literal: true

require "bigdecimal"

module RubyDB
  module Types
    # Arbitrary precision decimal
    class Decimal < Type
      attr_reader :precision, :scale

      def initialize(precision: 10, scale: 2)
        super(:decimal, precision: precision, scale: scale)
        @precision = precision
        @scale = scale
      end

      def serialize(value)
        validate(value)
        bd = value.is_a?(BigDecimal) ? value : BigDecimal(value.to_s)
        bd.to_s("F").encode("UTF-8")
      end

      def deserialize(bytes)
        return nil if bytes.nil? || bytes.empty?
        str = bytes.force_encoding("UTF-8")
        BigDecimal(str)
      end

      def validate(value)
        return true if value.nil?
        bd = value.is_a?(BigDecimal) ? value : BigDecimal(value.to_s)
        raise ConstraintError, "Invalid decimal: #{value}" unless bd
        true
      rescue ArgumentError, TypeError
        raise ConstraintError, "Invalid decimal: #{value}"
      end

      def default
        BigDecimal("0")
      end

      def storage_size
        # Variable length, stored as string
        nil
      end
    end
  end
end