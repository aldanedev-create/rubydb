# frozen_string_literal: true

module RubyDB
  # Raised when SQL parsing fails
  class ParserError < Error
    def initialize(message = "SQL parsing error", details: nil)
      super(message, code: ErrorCodes::ERROR, details: details)
    end
  end
end