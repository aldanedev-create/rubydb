# frozen_string_literal: true

module RubyDB
  # Raised for client-side lifecycle and protocol usage errors.
  class ClientError < Error
    def initialize(message = "Client error", details: nil)
      super(message, code: ErrorCodes::ERROR, details: details)
    end
  end
end
