# frozen_string_literal: true

require "time"

module RubyDB
  module MVCC
    # Version - Represents a version of a row
    class Version
      attr_reader :row_id, :version_id, :created_at, :transaction_id
      attr_reader :data, :prev_version_id, :next_version_id
      attr_accessor :is_committed, :is_aborted, :is_deleted
      attr_reader :commit_id, :committed_at, :aborted_at, :visibility

      def initialize(row_id, data, transaction_id, prev_version_id = nil)
        @row_id = row_id
        @version_id = generate_version_id
        @data = data
        @transaction_id = transaction_id
        @prev_version_id = prev_version_id
        @next_version_id = nil
        @created_at = Time.now
        @is_committed = false
        @is_aborted = false
        @is_deleted = false
        @commit_id = nil
        @visibility = :active  # :active, :visible, :hidden, :deleted
        @lock = Mutex.new
      end

      def generate_version_id
        "#{row_id}_#{Time.now.to_i}_#{rand(10000)}"
      end

      def commit(commit_id = nil)
        @lock.synchronize do
          @commit_id = commit_id || transaction_id
          @is_committed = true
          @visibility = :visible
          @committed_at = Time.now
        end
      end

      def abort
        @lock.synchronize do
          @is_aborted = true
          @visibility = :hidden
          @aborted_at = Time.now
        end
      end

      def mark_deleted
        @lock.synchronize do
          @is_deleted = true
          @visibility = :deleted
        end
      end

      def visible_to?(transaction_id, snapshot = nil)
        @lock.synchronize do
          # Check snapshot first
          if snapshot
            return snapshot.visible?(self, transaction_id)
          end

          # If not committed, only visible to its own transaction
          return false unless @is_committed

          # Check if deleted
          return false if @is_deleted && @visibility == :deleted

          # Committed versions are visible to all transactions
          # except those that started before this version was committed
          if @commit_id && transaction_id
            return @commit_id <= transaction_id
          end

          true
        end
      end

      def to_hash
        {
          row_id: @row_id,
          version_id: @version_id,
          created_at: @created_at.iso8601,
          transaction_id: @transaction_id,
          prev_version_id: @prev_version_id,
          next_version_id: @next_version_id,
          is_committed: @is_committed,
          is_aborted: @is_aborted,
          is_deleted: @is_deleted,
          visibility: @visibility,
          commit_id: @commit_id
        }
      end

      def inspect
        "#<Version row_id=#{@row_id} version=#{@version_id} txn=#{@transaction_id} visibility=#{@visibility}>"
      end

      def to_s
        inspect
      end
    end
  end
end
