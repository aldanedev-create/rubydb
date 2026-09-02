# frozen_string_literal: true

require "set"
require "time"

module RubyDB
  module MVCC
    # Snapshot - Represents a consistent view of the database at a point in time
    class Snapshot
      attr_reader :id, :transaction_id, :created_at
      attr_reader :active_transactions, :committed_transactions
      attr_reader :min_transaction_id, :max_transaction_id
      attr_reader :read_keys, :write_keys, :read_predicates

      def initialize(transaction_id, active_transactions = [], committed_transactions = [])
        @id = generate_snapshot_id(transaction_id)
        @transaction_id = transaction_id
        @created_at = Time.now
        @active_transactions = Set.new(active_transactions)
        @committed_transactions = Set.new(committed_transactions)
        @min_transaction_id = active_transactions.min || 0
        @max_transaction_id = active_transactions.max || 0
        @version_cache = {}
        @read_keys = Set.new
        @write_keys = Set.new
        @read_predicates = Set.new
        @cache_size = 1000
        @lock = Mutex.new
      end

      def record_read(key)
        @lock.synchronize { @read_keys.add(key) }
      end

      def record_write(key)
        @lock.synchronize { @write_keys.add(key) }
      end

      def record_predicate(predicate)
        @lock.synchronize { @read_predicates.add(predicate) }
      end

      def generate_snapshot_id(transaction_id)
        "snapshot_#{transaction_id}_#{Time.now.to_i}_#{rand(10000)}"
      end

      def visible?(version, check_transaction_id = nil)
        @lock.synchronize do
          # Check cache
          cache_key = version.version_id
          if @version_cache.key?(cache_key)
            return @version_cache[cache_key]
          end

          result = check_visibility(version, check_transaction_id)

          # Cache result
          if @version_cache.size < @cache_size
            @version_cache[cache_key] = result
          end

          result
        end
      end

      def check_visibility(version, check_transaction_id = nil)
        txn_id = check_transaction_id || @transaction_id

        # Same transaction sees its own versions
        return true if version.transaction_id == txn_id

        # Check if version is from an active transaction
        if @active_transactions.include?(version.transaction_id)
          # Active transactions are not visible (unless it's the current transaction)
          return false
        end

        # Check if version is from a committed transaction
        if version.is_committed && @committed_transactions.include?(version.transaction_id)
          # Check if the commit happened after snapshot was taken
          if version.committed_at && version.committed_at > @created_at
            return false
          end
          return true
        end

        # If transaction is not in our lists, it committed before snapshot
        if version.is_committed
          # Check if it was committed before snapshot
          if version.commit_id && version.commit_id < @min_transaction_id
            return true
          end
        end

        # Default: not visible
        false
      end

      def add_active_transaction(transaction_id)
        @lock.synchronize do
          @active_transactions.add(transaction_id)
          @min_transaction_id = [@min_transaction_id, transaction_id].min
          @max_transaction_id = [@max_transaction_id, transaction_id].max
        end
      end

      def add_committed_transaction(transaction_id)
        @lock.synchronize do
          @committed_transactions.add(transaction_id)
          @active_transactions.delete(transaction_id)
        end
      end

      def remove_transaction(transaction_id)
        @lock.synchronize do
          @active_transactions.delete(transaction_id)
          @committed_transactions.delete(transaction_id)
        end
      end

      def includes_transaction?(transaction_id)
        @active_transactions.include?(transaction_id) ||
        @committed_transactions.include?(transaction_id)
      end

      def to_hash
        {
          id: @id,
          transaction_id: @transaction_id,
          created_at: @created_at.iso8601,
          active_transactions: @active_transactions.to_a,
          committed_transactions: @committed_transactions.to_a,
          min_transaction_id: @min_transaction_id,
          max_transaction_id: @max_transaction_id
        }
      end

      def inspect
        "#<Snapshot id=#{@id} txn=#{@transaction_id} active=#{@active_transactions.size} committed=#{@committed_transactions.size}>"
      end

      def to_s
        inspect
      end
    end
  end
end
