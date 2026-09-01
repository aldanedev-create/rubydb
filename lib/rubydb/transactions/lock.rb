# frozen_string_literal: true

module RubyDB
  module Transactions
    # Lock - Represents a lock on a resource
    class Lock
      attr_reader :key, :type, :holders, :waiters, :created_at
      
      # Lock types
      SHARED = :shared
      EXCLUSIVE = :exclusive
      UPDATE = :update
      INTENT = :intent

      def initialize(key, type, holder = nil)
        @key = key
        @type = type
        @holders = {}
        @waiters = {}
        @created_at = Time.now
        
        add_holder(holder, type) if holder
      end

      def add_holder(transaction, type)
        @holders[transaction.id] = type
        @type = type if type == EXCLUSIVE
      end

      def remove_holder(transaction)
        @holders.delete(transaction.id)
        @type = SHARED if @holders.empty?
      end

      def add_waiter(transaction, type)
        @waiters[transaction.id] = type
      end

      def remove_waiter(transaction)
        @waiters.delete(transaction.id)
      end

      def shared?
        @type == SHARED
      end

      def exclusive?
        @type == EXCLUSIVE
      end

      def update?
        @type == UPDATE
      end

      def intent?
        @type == INTENT
      end

      def holder_count
        @holders.size
      end

      def waiter_count
        @waiters.size
      end

      def to_s
        "Lock(key=#{@key}, type=#{@type}, holders=#{@holders.size}, waiters=#{@waiters.size})"
      end

      def inspect
        to_s
      end
    end
  end
end