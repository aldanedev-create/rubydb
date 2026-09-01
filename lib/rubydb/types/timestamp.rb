# frozen_string_literal: true

require "time"

module RubyDB
  module Types
    # Timestamp (date + time with timezone)
    class Timestamp < Type
      SIZE = 8  # Seconds since epoch (Unix timestamp)

      def initialize
        super(:timestamp, size: SIZE)
      end

      def serialize(value)
        validate(value)
        return "\x00" * SIZE if value.nil?
        [value.to_i].pack("q>")
      end

      def deserialize(bytes)
        return nil if bytes.nil? || bytes.empty?
        seconds = bytes.unpack("q>").first
        ::Time.at(seconds)
      end

      def validate(value)
        return true if value.nil?
        raise ConstraintError, "Invalid timestamp: #{value}" unless value.is_a?(::Time) || value.is_a?(::DateTime) || value.is_a?(::Date)
        true
      end

      def default
        ::Time.now
      end
    end
  end
end