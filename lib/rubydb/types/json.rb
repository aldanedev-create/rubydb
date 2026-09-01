# frozen_string_literal: true

require "json"

module RubyDB
  module Types
    # JSON type (stores JSON data)
    class Json < Type
      def initialize
        super(:json)
      end

      def serialize(value)
        validate(value)
        return "null".encode("UTF-8") if value.nil?
        JSON.generate(value)
      end

      def deserialize(bytes)
        return nil if bytes.nil? || bytes.empty?
        JSON.parse(bytes.force_encoding("UTF-8"))
      rescue JSON::ParserError
        nil
      end

      def validate(value)
        return true if value.nil?
        raise ConstraintError, "Invalid JSON: #{value}" unless value.is_a?(Hash) || value.is_a?(Array)
        true
      end

      def default
        {}
      end

      def storage_size
        nil  # Variable length
      end
    end
  end
end