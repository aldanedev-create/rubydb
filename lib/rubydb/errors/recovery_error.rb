# frozen_string_literal: true

module RubyDB
  # Raised when recovery from crash fails
  class RecoveryError < Error
    def initialize(message = "Recovery failed", details: nil)
      super(message, code: ErrorCodes::ERROR, details: details)
    end
  end
end