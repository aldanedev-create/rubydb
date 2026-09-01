# frozen_string_literal: true

require "time"

module RubyDB
  module Types
    # Time type (hour, minute, second)
    class Time < Type
      SIZE = 8  # Microseconds since midnight

      def initialize
        super(:time, size: SIZE)
      end

      def serialize(value)
        validate(value)
        return "\x00" * SIZE if value.nil?
        seconds = value.hour * 3600 + value.min * 60 + value.sec
        microseconds = value.usec
        total = seconds * 1_000_000 + microseconds
        [total].pack("q>")
      end

      def deserialize(bytes)
        return nil if bytes.nil? || bytes.empty?
        total = bytes.unpack("q>").first
        seconds = total / 1_000_000
        microseconds = total % 1_000_000
        hour = seconds / 3600
        minute = (seconds % 3600) / 60
        sec = seconds % 60
        ::Time.new(1970, 1, 1, hour, minute, sec, microseconds)
      end

      def validate(value)
        return true if value.nil?
        raise ConstraintError, "Invalid time: #{value}" unless value.is_a?(::Time) || value.is_a?(::DateTime)
        true
      end

      def default
        ::Time.now
      end
    end
  end
end