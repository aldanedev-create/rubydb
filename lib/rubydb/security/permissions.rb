# frozen_string_literal: true

module RubyDB
  module Security
    # Permissions - Permission definitions and management
    class Permissions
      # Standard permissions
      SELECT = "SELECT"
      INSERT = "INSERT"
      UPDATE = "UPDATE"
      DELETE = "DELETE"
      CREATE = "CREATE"
      DROP = "DROP"
      ALTER = "ALTER"
      INDEX = "INDEX"
      GRANT = "GRANT"
      REVOKE = "REVOKE"
      EXECUTE = "EXECUTE"
      CONNECT = "CONNECT"
      USAGE = "USAGE"
      ALL = "ALL"

      # Permission groups
      GROUPS = {
        read: [SELECT],
        write: [INSERT, UPDATE, DELETE],
        ddl: [CREATE, DROP, ALTER],
        admin: [GRANT, REVOKE],
        all: [SELECT, INSERT, UPDATE, DELETE, CREATE, DROP, ALTER, INDEX, EXECUTE]
      }

      def initialize
        @permissions = {}
        @lock = Mutex.new
      end

      def define_permission(name, description = nil)
        @lock.synchronize do
          @permissions[name] = {
            description: description || "Permission to #{name}",
            created_at: Time.now
          }
        end
      end

      def permission_exists?(name)
        @permissions.key?(name)
      end

      def list_permissions
        @permissions.keys
      end

      def describe_permission(name)
        @permissions[name]
      end

      def group_permissions(group)
        GROUPS[group] || []
      end

      def permission_names
        @permissions.keys
      end

      def to_hash
        {
          permissions: @permissions,
          groups: GROUPS
        }
      end
    end
  end
end