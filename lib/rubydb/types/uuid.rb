# frozen_string_literal: true

require "securerandom"

module RubyDB
  module Types
    # UUID type (Universally Unique Identifier)
    class UUID < Type
      SIZE = 16
      UUID_REGEX = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

      def initialize
        super(:uuid, size: SIZE)
      end

      def serialize(value)
        validate(value)
        return "\x00" * SIZE if value.nil?
        # Remove hyphens and convert hex to bytes
        hex = value.to_s.gsub("-", "")
        [hex].pack("H*")
      end

      def deserialize(bytes)
        return nil if bytes.nil? || bytes.empty?
        hex = bytes.unpack("H*").first
        # Add hyphens back
        "#{hex[0...8]}-#{hex[8...12]}-#{hex[12...16]}-#{hex[16...20]}-#{hex[20...32]}"
      end

      def validate(value)
        return true if value.nil?
        str = value.to_s
        raise ConstraintError, "Invalid UUID: #{value}" unless str.match?(UUID_REGEX)
        true
      end

      def default
        SecureRandom.uuid
      end

      def generate
        SecureRandom.uuid
      end
    end
  end
end