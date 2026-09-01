# frozen_string_literal: true

module RubyDB
  module Types
    # Binary large object (arbitrary binary data)
    class Blob < Type
      def initialize
        super(:blob)
      end

      def serialize(value)
        validate(value)
        return "".b if value.nil?
        value.is_a?(String) ? value.b : value.to_s.b
      end

      def deserialize(bytes)
        return nil if bytes.nil? || bytes.empty?
        bytes.b
      end

      def validate(value)
        return true if value.nil?
        raise ConstraintError, "Invalid blob: #{value}" unless value.respond_to?(:to_s)
        true
      end

      def default
        "".b
      end

      def storage_size
        nil  # Variable length
      end
    end
  end
end