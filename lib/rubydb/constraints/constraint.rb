# frozen_string_literal: true

module RubyDB
  module Constraints
    # Constraint - Base class for all constraints
    class Constraint
      attr_reader :name, :type, :table_name, :options, :created_at

      # Constraint types
      TYPE_PRIMARY_KEY = :primary_key
      TYPE_FOREIGN_KEY = :foreign_key
      TYPE_UNIQUE = :unique
      TYPE_NOT_NULL = :not_null
      TYPE_CHECK = :check

      def initialize(name, type, table_name, options = {})
        @name = name || generate_name(type, table_name)
        @type = type
        @table_name = table_name
        @options = options
        @created_at = Time.now
        @enabled = options[:enabled] != false
        @deferrable = options[:deferrable] || false
        @deferred = options[:deferred] || false
        @validated = false
        @validation_errors = []
      end

      def validate(row)
        raise NotImplementedError, "#{self.class} must implement #validate"
      end

      def validate_batch(rows)
        results = { valid: [], invalid: [] }
        rows.each do |row|
          if validate(row)
            results[:valid] << row
          else
            results[:invalid] << row
          end
        end
        results
      end

      def enabled?
        @enabled
      end

      def enable
        @enabled = true
      end

      def disable
        @enabled = false
      end

      def deferrable?
        @deferrable
      end

      def deferred?
        @deferred
      end

      def defer
        @deferred = true if @deferrable
      end

      def immediate
        @deferred = false if @deferrable
      end

      def to_sql
        raise NotImplementedError, "#{self.class} must implement #to_sql"
      end

      def to_hash
        {
          name: @name,
          type: @type,
          table_name: @table_name,
          options: @options,
          enabled: @enabled,
          deferrable: @deferrable,
          deferred: @deferred,
          created_at: @created_at.iso8601
        }
      end

      def inspect
        "#<Constraint name=#{@name} type=#{@type} table=#{@table_name}>"
      end

      private

      def generate_name(type, table_name)
        "#{table_name}_#{type}_#{Time.now.to_i}_#{rand(1000)}"
      end
    end
  end
end