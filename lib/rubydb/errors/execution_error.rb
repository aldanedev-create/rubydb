# frozen_string_literal: true

module RubyDB
  # Raised when query execution fails
  class ExecutionError < Error
    def initialize(message = "Execution error", details: nil)
      super(message, code: ErrorCodes::ERROR, details: details)
    end
  end
end