# frozen_string_literal: true

module RubyDB
  module Types
    # NULL type (represents absence of value)
    class Null < Type
      SIZE = 0

      def initialize
        super(:null, size: SIZE)
      end

      def serialize(value)
        ""
      end

      def deserialize(bytes)
        nil
      end

      def validate(value)
        true  # Always valid
      end

      def default
        nil
      end

      def storage_size
        0
      end
    end
  end
end