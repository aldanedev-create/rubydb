# frozen_string_literal: true

module RubyDB
  # Raised when there is an error connecting to the database
  class ConnectionError < Error
    def initialize(message = "Connection error", details: nil)
      super(message, code: ErrorCodes::ERROR, details: details)
    end
  end
end