# frozen_string_literal: true

require "securerandom"
require "time"


# Import dependencies
require_relative "savepoint"      # For Savepoint class
require_relative "transaction_id"

module RubyDB
  module Transactions
    # Transaction - Represents a database transaction
    class Transaction
      attr_reader :id, :start_time, :status, :isolation_level, :read_only
      attr_reader :savepoints, :locked_rows, :modified_rows, :accessed_tables
      attr_accessor :parent_transaction

      # Transaction statuses
      STATUS_ACTIVE = :active
      STATUS_COMMITTED = :committed
      STATUS_ABORTED = :aborted
      STATUS_PREPARED = :prepared
      STATUS_IN_DOUBT = :in_doubt

      def initialize(options = {})
        @id = options[:id] || generate_id
        @start_time = Time.now
        @status = STATUS_ACTIVE
        @isolation_level = options[:isolation_level] || :read_committed
        @read_only = options[:read_only] || false
        @parent_transaction = options[:parent]
        @savepoints = []
        @locked_rows = {}
        @modified_rows = {}
        @accessed_tables = Set.new
        @changes = []
        @undo_log = []
        @timeout = options[:timeout] || 30  # 30 seconds default
        @deadline = @start_time + @timeout
        @lock = Mutex.new
        @name = options[:name]
        @priority = options[:priority] || 0
      end

      def active?
        @status == STATUS_ACTIVE
      end

      def committed?
        @status == STATUS_COMMITTED
      end

      def aborted?
        @status == STATUS_ABORTED
      end

      def prepared?
        @status == STATUS_PREPARED
      end

      def in_doubt?
        @status == STATUS_IN_DOUBT
      end

      def expired?
        Time.now > @deadline
      end

      def add_change(change)
        @lock.synchronize do
          @changes << change
          @undo_log << create_undo_entry(change)
        end
      end

      def add_modified_row(table_name, row_id, old_value, new_value)
        @lock.synchronize do
          @modified_rows[row_id] ||= {
            table: table_name,
            old: old_value,
            new: new_value,
            timestamp: Time.now
          }
        end
      end

      def add_locked_row(table_name, row_id, lock_type)
        @lock.synchronize do
          key = "#{table_name}:#{row_id}"
          @locked_rows[key] = {
            table: table_name,
            row_id: row_id,
            lock_type: lock_type,
            timestamp: Time.now
          }
        end
      end

      def add_accessed_table(table_name)
        @lock.synchronize do
          @accessed_tables.add(table_name)
        end
      end

      def create_savepoint(name = nil)
        @lock.synchronize do
          savepoint = Savepoint.new(name || "savepoint_#{@savepoints.size + 1}", self)
          @savepoints << savepoint
          savepoint
        end
      end

      def rollback_to_savepoint(name)
        @lock.synchronize do
          index = @savepoints.index { |sp| sp.name == name }
          return false unless index

          # Rollback changes after this savepoint
          @savepoints[index + 1..-1].each do |sp|
            sp.rollback
          end
          @savepoints = @savepoints[0..index]

          true
        end
      end

      def release_savepoint(name)
        @lock.synchronize do
          index = @savepoints.index { |sp| sp.name == name }
          return false unless index

          @savepoints.delete_at(index)
          true
        end
      end

      def commit
        @lock.synchronize do
          return false unless active?
          @status = STATUS_COMMITTED
          @commit_time = Time.now
          true
        end
      end

      def abort
        @lock.synchronize do
          return false unless active?
          @status = STATUS_ABORTED
          @abort_time = Time.now
          true
        end
      end

      def prepare
        @lock.synchronize do
          return false unless active?
          @status = STATUS_PREPARED
          @prepare_time = Time.now
          true
        end
      end

      def mark_in_doubt
        @lock.synchronize do
          @status = STATUS_IN_DOUBT
          @in_doubt_time = Time.now
        end
      end

      def to_hash
        {
          id: @id,
          start_time: @start_time.iso8601,
          status: @status,
          isolation_level: @isolation_level,
          read_only: @read_only,
          changes: @changes.size,
          locked_rows: @locked_rows.size,
          modified_rows: @modified_rows.size,
          accessed_tables: @accessed_tables.to_a,
          savepoints: @savepoints.map(&:name),
          timeout: @timeout,
          expired: expired?
        }
      end

      def inspect
        "#<Transaction id=#{@id} status=#{@status} isolation=#{@isolation_level}>"
      end

      def to_s
        inspect
      end

      private

      def generate_id
        "txn_#{Time.now.to_i}_#{SecureRandom.hex(8)}"
      end

      def create_undo_entry(change)
        {
          change: change,
          timestamp: Time.now,
          type: change[:type]
        }
      end
    end
  end
end