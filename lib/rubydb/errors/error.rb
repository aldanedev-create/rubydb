# frozen_string_literal: true

module RubyDB
  # Base error class for all RubyDB errors
  class Error < StandardError
    attr_reader :code, :details

    def initialize(message = nil, code: nil, details: nil)
      super(message)
      @code = code || ErrorCodes::ERROR
      @details = details || {}
    end

    def to_s
      msg = super
      msg = "#{msg} (code: #{@code})" if @code
      msg
    end
  end
end