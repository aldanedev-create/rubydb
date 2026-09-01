# frozen_string_literal: true

module RubyDB
  # Raised when there is an error in database configuration
  class ConfigurationError < Error
    def initialize(message = "Configuration error", details: nil)
      super(message, code: ErrorCodes::ERROR, details: details)
    end
  end
end