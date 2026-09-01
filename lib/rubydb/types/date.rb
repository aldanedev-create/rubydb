# frozen_string_literal: true

require "date"

module RubyDB
  module Types
    # Date type (year, month, day)
    class Date < Type
      SIZE = 4  # Days since epoch (stored as integer)

      def initialize
        super(:date, size: SIZE)
      end

      def serialize(value)
        validate(value)
        return "\x00" * SIZE if value.nil?
        days = value - Date.new(1970, 1, 1)
        [days.to_i].pack("l>")
      end

      def deserialize(bytes)
        return nil if bytes.nil? || bytes.empty?
        days = bytes.unpack("l>").first
        Date.new(1970, 1, 1) + days
      end

      def validate(value)
        return true if value.nil?
        raise ConstraintError, "Invalid date: #{value}" unless value.is_a?(::Date) || value.is_a?(::DateTime)
        true
      end

      def default
        Date.today
      end
    end
  end
end