# frozen_string_literal: true

module RubyDB
  # Raised when database corruption is detected
  class CorruptionError < Error
    def initialize(message = "Database corruption detected", details: nil)
      super(message, code: ErrorCodes::CORRUPTION, details: details)
    end
  end
end