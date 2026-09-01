# frozen_string_literal: true

module RubyDB
  # Raised when there is an error with transactions
  class TransactionError < Error
    def initialize(message = "Transaction error", details: nil)
      super(message, code: ErrorCodes::TRANSACTION_ABORTED, details: details)
    end
  end
end