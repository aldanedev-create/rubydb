# frozen_string_literal: true

module RubyDB
  module Types
    # Variable-length text string with maximum length
    class Varchar < Text
      attr_reader :limit

      def initialize(limit)
        super()
        @name = :varchar
        @limit = limit
        @size = limit
      end

      def serialize(value)
        validate(value)
        return "" if value.nil?
        str = value.to_s.encode("UTF-8")
        raise ConstraintError, "VARCHAR exceeds limit: #{str.length} > #{@limit}" if str.length > @limit
        str
      end

      def validate(value)
        return true if value.nil?
        raise ConstraintError, "Invalid varchar: #{value}" unless value.respond_to?(:to_s)
        str = value.to_s
        raise ConstraintError, "VARCHAR exceeds limit: #{str.length} > #{@limit}" if str.length > @limit
        true
      end

      def to_s
        "VARCHAR(#{@limit})"
      end
    end
  end
end