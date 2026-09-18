# frozen_string_literal: true

module RubyDB
  module Accelerator
    class Error < StandardError
      attr_reader :code

      def initialize(message, code: nil)
        @code = code
        super(message)
      end
    end

    class UnavailableError < Error; end

    class ProtocolError < Error; end

    class RequestError < Error; end

    class TimeoutError < Error; end
  end
end
