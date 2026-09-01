# frozen_string_literal: true

module RubyDB
  # Raised when authorization fails (permission denied)
  class AuthorizationError < Error
    attr_reader :user, :action, :resource

    def initialize(message = "Permission denied", user: nil, action: nil, resource: nil, details: nil)
      super(message, code: ErrorCodes::PERMISSION_DENIED, details: details)
      @user = user
      @action = action
      @resource = resource
    end

    def to_s
      msg = super
      msg = "#{msg} for user #{@user}" if @user
      msg = "#{msg} to #{@action}" if @action
      msg = "#{msg} on #{@resource}" if @resource
      msg
    end
  end
end