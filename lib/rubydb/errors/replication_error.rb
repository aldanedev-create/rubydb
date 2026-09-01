# frozen_string_literal: true

module RubyDB
  # Raised when there is an error with replication
  class ReplicationError < Error
    def initialize(message = "Replication error", details: nil)
      super(message, code: ErrorCodes::ERROR, details: details)
    end
  end
end