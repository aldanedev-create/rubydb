# frozen_string_literal: true

require "time"

module RubyDB
  module Security
    # User - User account
    class User
      attr_reader :username, :created_at, :last_login, :attributes
      attr_accessor :password_hash, :salt, :email, :full_name, :superuser
      attr_accessor :active, :locked, :expires_at, :metadata

      def initialize(username, options = {})
        @username = username
        @password_hash = options[:password_hash]
        @salt = options[:salt]
        @email = options[:email]
        @full_name = options[:full_name]
        @superuser = options[:superuser] || false
        @active = options[:active] != false
        @locked = options[:locked] || false
        @created_at = Time.now
        @last_login = nil
        @expires_at = options[:expires_at]
        @metadata = options[:metadata] || {}
        @attributes = options[:attributes] || {}
      end

      def authenticate(password, password_hasher)
        return false unless @active && !@locked
        return false if expired?
        password_hasher.verify(password, @password_hash)
      end

      def login
        @last_login = Time.now
        @locked = false
      end

      def lock
        @locked = true
      end

      def unlock
        @locked = false
      end

      def activate
        @active = true
      end

      def deactivate
        @active = false
      end

      def expired?
        return false unless @expires_at
        Time.now > @expires_at
      end

      def to_hash
        {
          username: @username,
          email: @email,
          full_name: @full_name,
          superuser: @superuser,
          active: @active,
          locked: @locked,
          created_at: @created_at.iso8601,
          last_login: @last_login&.iso8601,
          expires_at: @expires_at&.iso8601,
          metadata: @metadata,
          attributes: @attributes
        }
      end

      def to_json
        JSON.generate(to_hash)
      end

      def inspect
        "#<User username=#{@username} active=#{@active} superuser=#{@superuser}>"
      end
    end
  end
end