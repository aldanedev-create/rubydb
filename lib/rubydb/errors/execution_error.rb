# frozen_string_literal: true

module RubyDB
  # Raised when query execution fails
  class ExecutionError < Error
    def initialize(message = "Execution error", code: ErrorCodes::ERROR, details: nil)
      super(message, code: code, details: details)
    end
  end
end
