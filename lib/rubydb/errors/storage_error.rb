# frozen_string_literal: true

module RubyDB
  # Raised when there is an error with storage operations
  class StorageError < Error
    def initialize(message = "Storage error", details: nil)
      super(message, code: ErrorCodes::IO_ERROR, details: details)
    end
  end
end