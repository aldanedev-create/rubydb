# frozen_string_literal: true

module RubyDB
  module Types
    # Variable-length text string (unlimited)
    class Text < Type
      def initialize
        super(:text)
      end

      def serialize(value)
        validate(value)
        return "" if value.nil?
        value.to_s.encode("UTF-8")
      end

      def deserialize(bytes)
        return nil if bytes.nil? || bytes.empty?
        bytes.force_encoding("UTF-8")
      end

      def validate(value)
        return true if value.nil?
        raise ConstraintError, "Invalid text: #{value}" unless value.respond_to?(:to_s)
        true
      end

      def default
        ""
      end

      def storage_size
        nil  # Variable length
      end
    end
  end
end