# frozen_string_literal: true

module RubyDB
  # Raised when authentication fails
  class AuthenticationError < Error
    def initialize(message = "Authentication failed", details: nil)
      super(message, code: ErrorCodes::PERMISSION_DENIED, details: details)
    end
  end
end