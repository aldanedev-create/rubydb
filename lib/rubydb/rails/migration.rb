# frozen_string_literal: true

module RubyDB
  module Rails
    # Migration - Rails migration support
    class Migration
      attr_reader :version, :name, :connection, :direction

      def initialize(version, name, connection)
        @version = version
        @name = name
        @connection = connection
        @direction = :up
        @migrated = false
      end

      def up(&block)
        @direction = :up
        instance_eval(&block) if block_given?
        @migrated = true
      end

      def down(&block)
        @direction = :down
        instance_eval(&block) if block_given?
        @migrated = true
      end

      def migrate(direction = :up)
        @direction = direction
        if direction == :up
          up { yield if block_given? }
        else
          down { yield if block_given? }
        end
      end

      def method_missing(method, *args, &block)
        if @connection.respond_to?(method)
          @connection.send(method, *args, &block)
        else
          super
        end
      end

      def respond_to_missing?(method, include_private = false)
        @connection.respond_to?(method) || super
      end

      def create_table(table_name, options = {}, &block)
        @connection.create_table(table_name, options, &block)
      end

      def drop_table(table_name, options = {})
        @connection.drop_table(table_name, options)
      end

      def add_column(table_name, column_name, type, options = {})
        @connection.add_column(table_name, column_name, type, options)
      end

      def remove_column(table_name, column_name, options = {})
        @connection.remove_column(table_name, column_name, options)
      end

      def change_column(table_name, column_name, type, options = {})
        @connection.change_column(table_name, column_name, type, options)
      end

      def rename_column(table_name, old_name, new_name)
        @connection.rename_column(table_name, old_name, new_name)
      end

      def add_index(table_name, column_name, options = {})
        @connection.add_index(table_name, column_name, options)
      end

      def remove_index(table_name, options = {})
        @connection.remove_index(table_name, options)
      end

      def add_foreign_key(from_table, to_table, options = {})
        @connection.add_foreign_key(from_table, to_table, options)
      end

      def remove_foreign_key(from_table, options = {})
        @connection.remove_foreign_key(from_table, options)
      end

      def add_timestamps(table_name, options = {})
        @connection.add_timestamps(table_name, options)
      end

      def remove_timestamps(table_name, options = {})
        @connection.remove_timestamps(table_name, options)
      end

      def change_column_null(table_name, column_name, null, default = nil)
        @connection.change_column_null(table_name, column_name, null, default)
      end

      def change_column_default(table_name, column_name, default)
        @connection.change_column_default(table_name, column_name, default)
      end

      def execute(sql)
        @connection.execute(sql)
      end

      def quote(value)
        @connection.quote(value)
      end

      def quote_table_name(name)
        @connection.quote_table_name(name)
      end

      def quote_column_name(name)
        @connection.quote_column_name(name)
      end

      def migrate
        @migrated
      end

      def to_s
        "Migration #{@version} #{@name} (#{@direction})"
      end
    end
  end
end
