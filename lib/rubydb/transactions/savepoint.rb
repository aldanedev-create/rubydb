# frozen_string_literal: true

module RubyDB
  module Transactions

    # Import transaction dependency
require_relative "transaction"
    # Savepoint - Represents a savepoint within a transaction
    class Savepoint
      attr_reader :name, :transaction, :created_at, :position
      attr_reader :modified_rows, :locked_rows, :changes

      def initialize(name, transaction)
        @name = name
        @transaction = transaction
        @created_at = Time.now
        @position = transaction.savepoints.size
        @modified_rows = {}
        @locked_rows = {}
        @changes = []
        @state = :active
        @lock = Mutex.new
        
        # Save current state
        save_state
      end

      def active?
        @state == :active
      end

      def released?
        @state == :released
      end

      def rollbacked?
        @state == :rollbacked
      end

      def rollback
        @lock.synchronize do
          return false unless active?
          
          # Rollback changes in reverse order
          @changes.reverse.each do |change|
            undo_change(change)
          end
          
          @state = :rollbacked
          true
        end
      end

      def release
        @lock.synchronize do
          return false unless active?
          @state = :released
          true
        end
      end

      def record_change(change)
        @lock.synchronize do
          @changes << change
        end
      end

      def record_modified_row(table_name, row_id, old_value, new_value)
        @lock.synchronize do
          @modified_rows[row_id] = {
            table: table_name,
            old: old_value,
            new: new_value
          }
        end
      end

      def record_locked_row(table_name, row_id, lock_type)
        @lock.synchronize do
          key = "#{table_name}:#{row_id}"
          @locked_rows[key] = {
            table: table_name,
            row_id: row_id,
            lock_type: lock_type
          }
        end
      end

      def to_hash
        {
          name: @name,
          position: @position,
          created_at: @created_at.iso8601,
          state: @state,
          changes: @changes.size,
          modified_rows: @modified_rows.size,
          locked_rows: @locked_rows.size
        }
      end

      def inspect
        "#<Savepoint name=#{@name} position=#{@position} state=#{@state}>"
      end

      private

      def save_state
        # Save current transaction state
        @transaction.modified_rows.each do |row_id, info|
          @modified_rows[row_id] = info.dup
        end
        @transaction.locked_rows.each do |key, info|
          @locked_rows[key] = info.dup
        end
      end

      def undo_change(change)
        case change[:type]
        when :insert
          # Delete inserted row
          @transaction.instance_variable_get(:@engine).delete_row(
            change[:table],
            change[:row_id]
          )
        when :update
          # Restore old values
          @transaction.instance_variable_get(:@engine).update_row(
            change[:table],
            change[:row_id],
            change[:old_values]
          )
        when :delete
          # Reinsert deleted row
          @transaction.instance_variable_get(:@engine).insert_row(
            change[:table],
            change[:columns],
            change[:row_data]
          )
        end
      end
    end
  end
end