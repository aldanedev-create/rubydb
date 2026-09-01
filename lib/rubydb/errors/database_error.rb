# frozen_string_literal: true

module RubyDB
  # Raised when there is a general database error
  class DatabaseError < Error
    def initialize(message = "Database error", details: nil)
      super(message, code: ErrorCodes::ERROR, details: details)
    end
  end
end