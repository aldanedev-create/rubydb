# frozen_string_literal: true

require "set"

module RubyDB
  module Security
    # Role - Role-based access control
    class Role
      attr_reader :name, :created_at, :metadata, :members
      attr_accessor :description, :parent_role

      def initialize(name, options = {})
        @name = name
        @description = options[:description]
        @parent_role = options[:parent_role]
        @members = Set.new
        @permissions = []
        @inherited_permissions = nil
        @created_at = Time.now
        @metadata = options[:metadata] || {}
      end

      def add_member(username)
        @members.add(username)
        invalidate_cache
      end

      def remove_member(username)
        @members.delete(username)
        invalidate_cache
      end

      def member?(username)
        @members.include?(username)
      end

      def members
        @members.to_a
      end

      def add_permission(permission)
        @permissions << permission unless @permissions.include?(permission)
        invalidate_cache
      end

      def remove_permission(permission)
        @permissions.delete(permission)
        invalidate_cache
      end

      def permissions
        @permissions.dup
      end

      def all_permissions(role_map = {})
        if @inherited_permissions.nil?
          @inherited_permissions = compute_all_permissions(role_map)
        end
        @inherited_permissions
      end

      def inherit_from(parent_role)
        @parent_role = parent_role
        invalidate_cache
      end

      def to_hash
        {
          name: @name,
          description: @description,
          parent_role: @parent_role,
          members: @members.to_a,
          permissions: @permissions,
          created_at: @created_at.iso8601,
          metadata: @metadata
        }
      end

      def inspect
        "#<Role name=#{@name} members=#{@members.size} permissions=#{@permissions.size}>"
      end

      private

      def invalidate_cache
        @inherited_permissions = nil
      end

      def compute_all_permissions(role_map)
        perms = @permissions.dup

        if @parent_role && role_map[@parent_role]
          parent = role_map[@parent_role]
          perms.concat(parent.all_permissions(role_map))
        end

        perms.uniq
      end
    end
  end
end