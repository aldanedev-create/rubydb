# frozen_string_literal: true

require "time"
require "json"

module RubyDB
  module History
    # Change - Represents a single change in history
    class Change
      attr_reader :id, :timestamp, :transaction_id, :table_name
      attr_reader :row_id, :operation, :old_values, :new_values
      attr_reader :user, :branch, :lsn, :metadata

      # Operation types
      OP_INSERT = :insert
      OP_UPDATE = :update
      OP_DELETE = :delete
      OP_CREATE_TABLE = :create_table
      OP_DROP_TABLE = :drop_table
      OP_ALTER_TABLE = :alter_table
      OP_CREATE_INDEX = :create_index
      OP_DROP_INDEX = :drop_index

      def initialize(attributes = {})
        @id = attributes[:id] || generate_change_id
        @timestamp = attributes[:timestamp] || Time.now
        @transaction_id = attributes[:transaction_id]
        @table_name = attributes[:table_name]
        @row_id = attributes[:row_id]
        @operation = attributes[:operation]
        @old_values = attributes[:old_values] || {}
        @new_values = attributes[:new_values] || {}
        @user = attributes[:user]
        @branch = attributes[:branch]
        @lsn = attributes[:lsn]
        @metadata = attributes[:metadata] || {}
      end

      def insert?
        @operation == OP_INSERT
      end

      def update?
        @operation == OP_UPDATE
      end

      def delete?
        @operation == OP_DELETE
      end

      def ddl?
        [:create_table, :drop_table, :alter_table, :create_index, :drop_index].include?(@operation)
      end

      def to_hash
        {
          id: @id,
          timestamp: @timestamp.iso8601,
          transaction_id: @transaction_id,
          table_name: @table_name,
          row_id: @row_id,
          operation: @operation,
          old_values: @old_values,
          new_values: @new_values,
          user: @user,
          branch: @branch,
          lsn: @lsn,
          metadata: @metadata
        }
      end

      def to_json
        JSON.generate(to_hash)
      end

      def self.from_json(json_data)
        data = JSON.parse(json_data, symbolize_names: true)
        new(
          id: data[:id],
          timestamp: Time.parse(data[:timestamp]),
          transaction_id: data[:transaction_id],
          table_name: data[:table_name],
          row_id: data[:row_id],
          operation: data[:operation].to_sym,
          old_values: data[:old_values],
          new_values: data[:new_values],
          user: data[:user],
          branch: data[:branch],
          lsn: data[:lsn],
          metadata: data[:metadata] || {}
        )
      end

      def inspect
        "#<Change id=#{@id} op=#{@operation} table=#{@table_name} row=#{@row_id}>"
      end

      private

      def generate_change_id
        "change_#{Time.now.to_i}_#{rand(10000)}"
      end
    end
  end
end