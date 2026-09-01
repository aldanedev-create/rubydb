# frozen_string_literal: true

module RubyDB
  module Security
    # Authorization - Handles permission checking
    class Authorization
      attr_reader :stats

      # Permission actions
      ACTION_SELECT = :select
      ACTION_INSERT = :insert
      ACTION_UPDATE = :update
      ACTION_DELETE = :delete
      ACTION_CREATE = :create
      ACTION_DROP = :drop
      ACTION_ALTER = :alter
      ACTION_INDEX = :index
      ACTION_GRANT = :grant
      ACTION_REVOKE = :revoke
      ACTION_EXECUTE = :execute
      ACTION_CONNECT = :connect
      ACTION_USAGE = :usage

      # Object types
      OBJECT_TABLE = :table
      OBJECT_VIEW = :view
      OBJECT_INDEX = :index
      OBJECT_DATABASE = :database
      OBJECT_SCHEMA = :schema
      OBJECT_FUNCTION = :function
      OBJECT_SEQUENCE = :sequence
      OBJECT_TRIGGER = :trigger

      def initialize(config = {})
        @config = config
        @default_deny = config[:default_deny] || true
        @permissions = {}
        @roles = {}
        @user_roles = {}
        @grant_options = {}
        @stats = {
          checks: 0,
          granted: 0,
          denied: 0,
          role_checks: 0,
          cache_hits: 0,
          cache_misses: 0
        }
        @cache = {}
        @cache_size = config[:cache_size] || 10000
        @lock = Mutex.new
      end

      def authorize(user, action, object, object_type = OBJECT_TABLE)
        @lock.synchronize do
          @stats[:checks] += 1

          # Check cache
          cache_key = "#{user.username}:#{action}:#{object}:#{object_type}"
          if @cache.key?(cache_key)
            @stats[:cache_hits] += 1
            return @cache[cache_key]
          end

          @stats[:cache_misses] += 1

          # Check if user is superuser
          if user.superuser?
            @cache[cache_key] = true
            @stats[:granted] += 1
            return true
          end

          # Check user permissions directly
          if check_user_permission(user, action, object, object_type)
            @cache[cache_key] = true
            @stats[:granted] += 1
            return true
          end

          # Check role permissions
          roles = get_user_roles(user)
          roles.each do |role|
            if check_role_permission(role, action, object, object_type)
              @cache[cache_key] = true
              @stats[:granted] += 1
              return true
            end
          end

          # Check if permission is granted to PUBLIC
          if check_public_permission(action, object, object_type)
            @cache[cache_key] = true
            @stats[:granted] += 1
            return true
          end

          # Default deny
          @cache[cache_key] = false if @cache.size < @cache_size
          @stats[:denied] += 1
          false
        end
      end

      def grant_permission(user, action, object, object_type = OBJECT_TABLE, options = {})
        @lock.synchronize do
          key = permission_key(action, object, object_type)
          @permissions[key] ||= { users: [], roles: [], public: false }

          if options[:grantor]
            @grant_options[key] ||= {}
            @grant_options[key][:grantor] = options[:grantor]
          end

          if options[:grant_option]
            @grant_options[key] ||= {}
            @grant_options[key][:grant_option] = true
          end

          if options[:role]
            @permissions[key][:roles] << options[:role]
          elsif options[:public]
            @permissions[key][:public] = true
          else
            @permissions[key][:users] << user.username
          end

          invalidate_cache
          true
        end
      end

      def revoke_permission(user, action, object, object_type = OBJECT_TABLE, options = {})
        @lock.synchronize do
          key = permission_key(action, object, object_type)
          perms = @permissions[key]
          return false unless perms

          if options[:role]
            perms[:roles].delete(options[:role])
          elsif options[:public]
            perms[:public] = false
          else
            perms[:users].delete(user.username)
          end

          @permissions.delete(key) if perms[:users].empty? && perms[:roles].empty? && !perms[:public]
          invalidate_cache
          true
        end
      end

      def add_role(role_name, parent_role = nil)
        @lock.synchronize do
          @roles[role_name] ||= { name: role_name, parent: parent_role }
          if parent_role
            @roles[parent_role] ||= { name: parent_role, parent: nil }
          end
          true
        end
      end

      def remove_role(role_name)
        @lock.synchronize do
          @roles.delete(role_name)
          @user_roles.each do |user, roles|
            roles.delete(role_name)
          end
          invalidate_cache
          true
        end
      end

      def assign_role(user, role_name)
        @lock.synchronize do
          @user_roles[user.username] ||= []
          @user_roles[user.username] << role_name unless @user_roles[user.username].include?(role_name)
          invalidate_cache
          true
        end
      end

      def revoke_role(user, role_name)
        @lock.synchronize do
          return false unless @user_roles[user.username]
          @user_roles[user.username].delete(role_name)
          invalidate_cache
          true
        end
      end

      def get_user_roles(user)
        @lock.synchronize do
          @stats[:role_checks] += 1
          roles = @user_roles[user.username] || []
          # Get parent roles recursively
          all_roles = []
          roles.each do |role|
            all_roles << role
            all_roles.concat(get_parent_roles(role))
          end
          all_roles.uniq
        end
      end

      def permissions_for_user(user)
        @lock.synchronize do
          result = []
          @permissions.each do |key, perms|
            if perms[:users].include?(user.username)
              result << key
            elsif perms[:public]
              result << key
            elsif (perms[:roles] & get_user_roles(user)).any?
              result << key
            end
          end
          result
        end
      end

      def clear_cache
        @lock.synchronize do
          @cache.clear
        end
      end

      def stats
        @lock.synchronize do
          @stats.merge({
            permissions: @permissions.size,
            roles: @roles.size,
            user_roles: @user_roles.size,
            cache_size: @cache.size,
            default_deny: @default_deny
          })
        end
      end

      private

      def permission_key(action, object, object_type)
        "#{action}:#{object_type}:#{object}"
      end

      def check_user_permission(user, action, object, object_type)
        key = permission_key(action, object, object_type)
        perms = @permissions[key]
        return false unless perms
        perms[:users].include?(user.username)
      end

      def check_role_permission(role, action, object, object_type)
        key = permission_key(action, object, object_type)
        perms = @permissions[key]
        return false unless perms
        perms[:roles].include?(role[:name])
      end

      def check_public_permission(action, object, object_type)
        key = permission_key(action, object, object_type)
        perms = @permissions[key]
        return false unless perms
        perms[:public]
      end

      def get_parent_roles(role_name)
        roles = []
        current = @roles[role_name]
        while current && current[:parent]
          roles << current[:parent]
          current = @roles[current[:parent]]
        end
        roles
      end

      def invalidate_cache
        @cache.clear if @cache.size > @cache_size
      end
    end
  end
end