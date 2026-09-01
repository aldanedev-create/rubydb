# frozen_string_literal: true

require "set"

module RubyDB
  module Security
    # AccessControl - Main access control system
    class AccessControl
      attr_reader :authentication, :authorization, :user_store
      attr_reader :role_store, :stats

      def initialize(config = {})
        @config = config
        @user_store = {}
        @role_store = {}
        @authentication = Authentication.new(config[:auth] || {})
        @authorization = Authorization.new(config[:authz] || {})
        @password_hasher = Password.new(config[:password] || {})
        @audit_log = AuditLog.new(config[:audit] || {})
        @stats = {
          access_checks: 0,
          granted: 0,
          denied: 0,
          user_operations: 0,
          role_operations: 0
        }
        @lock = Mutex.new

        # Create default admin user if none exists
        create_default_users if config[:create_defaults] != false
      end

      def create_user(username, password, options = {})
        @lock.synchronize do
          @stats[:user_operations] += 1

          if @user_store.key?(username)
            raise SecurityError, "User '#{username}' already exists"
          end

          salt = @password_hasher.generate_salt
          password_hash = @password_hasher.hash(password, salt)

          user = User.new(username, {
            password_hash: password_hash,
            salt: salt,
            email: options[:email],
            full_name: options[:full_name],
            superuser: options[:superuser] || false,
            active: options[:active] != false,
            expires_at: options[:expires_at],
            metadata: options[:metadata]
          })

          @user_store[username] = user
          @audit_log.log(:user_created, username: username)

          user
        end
      end

      def delete_user(username)
        @lock.synchronize do
          @stats[:user_operations] += 1

          return false unless @user_store.key?(username)
          @user_store.delete(username)
          @audit_log.log(:user_deleted, username: username)

          true
        end
      end

      def authenticate(username, password)
        @lock.synchronize do
          result = @authentication.authenticate(
            username: username,
            password: password
          )

          @audit_log.log(
            result[:success] ? :login_success : :login_failure,
            username: username,
            result: result
          )

          result
        end
      end

      def check_permission(user, action, object, object_type = Authorization::OBJECT_TABLE)
        @lock.synchronize do
          @stats[:access_checks] += 1

          result = @authorization.authorize(user, action, object, object_type)

          @audit_log.log(
            result ? :access_granted : :access_denied,
            username: user.username,
            action: action,
            object: object,
            result: result
          )

          if result
            @stats[:granted] += 1
          else
            @stats[:denied] += 1
          end

          result
        end
      end

      def create_role(name, options = {})
        @lock.synchronize do
          @stats[:role_operations] += 1

          if @role_store.key?(name)
            raise SecurityError, "Role '#{name}' already exists"
          end

          role = Role.new(name, options)
          @role_store[name] = role
          @authorization.add_role(name, options[:parent_role])

          @audit_log.log(:role_created, role: name)

          role
        end
      end

      def delete_role(name)
        @lock.synchronize do
          @stats[:role_operations] += 1

          return false unless @role_store.key?(name)
          @role_store.delete(name)
          @authorization.remove_role(name)

          @audit_log.log(:role_deleted, role: name)

          true
        end
      end

      def assign_role(username, role_name)
        @lock.synchronize do
          @stats[:role_operations] += 1

          user = @user_store[username]
          raise SecurityError, "User '#{username}' not found" unless user

          unless @role_store.key?(role_name)
            raise SecurityError, "Role '#{role_name}' not found"
          end

          @authorization.assign_role(user, role_name)
          @role_store[role_name].add_member(username)

          @audit_log.log(:role_assigned, username: username, role: role_name)

          true
        end
      end

      def revoke_role(username, role_name)
        @lock.synchronize do
          @stats[:role_operations] += 1

          user = @user_store[username]
          return false unless user

          @authorization.revoke_role(user, role_name)
          @role_store[role_name]&.remove_member(username)

          @audit_log.log(:role_revoked, username: username, role: role_name)

          true
        end
      end

      def grant_permission(permission, object, object_type, options = {})
        @lock.synchronize do
          @authorization.grant_permission(
            options[:grantor],
            permission,
            object,
            object_type,
            options
          )

          @audit_log.log(:permission_granted, permission: permission, object: object)

          true
        end
      end

      def revoke_permission(permission, object, object_type, options = {})
        @lock.synchronize do
          @authorization.revoke_permission(
            options[:grantor],
            permission,
            object,
            object_type,
            options
          )

          @audit_log.log(:permission_revoked, permission: permission, object: object)

          true
        end
      end

      def list_users
        @user_store.keys
      end

      def list_roles
        @role_store.keys
      end

      def get_user(username)
        @user_store[username]
      end

      def get_role(name)
        @role_store[name]
      end

      def stats
        @lock.synchronize do
          @stats.merge({
            users: @user_store.size,
            roles: @role_store.size,
            authentication: @authentication.stats,
            authorization: @authorization.stats,
            audit_log: @audit_log.stats
          })
        end
      end

      private

      def create_default_users
        # Create admin user if none exist
        if @user_store.empty?
          admin_password = @config[:admin_password] || "admin"
          create_user("admin", admin_password, superuser: true)
        end
      end
    end
  end
end