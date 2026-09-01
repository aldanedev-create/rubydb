# frozen_string_literal: true

module RubyDB
  module Transactions

    # Import dependencies
require_relative "transaction"
require_relative "transaction_log"

    # CommitManager - Manages two-phase commit and commit coordination
    class CommitManager
      attr_reader :stats

      def initialize(transaction_manager, config = {})
        @transaction_manager = transaction_manager
        @config = config
        @prepared_transactions = {}
        @commit_queue = []
        @stats = {
          prepared_count: 0,
          committed_count: 0,
          rolled_back_count: 0,
          in_doubt_count: 0,
          two_phase_commits: 0
        }
        @lock = Mutex.new
        @commit_thread = nil
        
        start_commit_thread if config[:async_commit] != false
      end

      def commit(transaction)
        @lock.synchronize do
          # Two-phase commit
          if @config[:two_phase_commit]
            two_phase_commit(transaction)
          else
            one_phase_commit(transaction)
          end
        end
      end

      def prepare(transaction)
        @lock.synchronize do
          # Validate that transaction can be prepared
          return false unless transaction.active?
          
          # Write prepare record to log
          @transaction_manager.transaction_log.log_prepare(transaction)
          
          # Store prepared transaction
          @prepared_transactions[transaction.id] = {
            transaction: transaction,
            prepared_at: Time.now,
            resources: transaction.modified_rows.keys
          }
          
          @stats[:prepared_count] += 1
          true
        end
      end

      def commit_prepared(transaction)
        @lock.synchronize do
          prepared = @prepared_transactions[transaction.id]
          return false unless prepared
          
          # Write commit record
          @transaction_manager.transaction_log.log_commit(transaction)
          
          # Commit changes
          commit_changes(transaction)
          
          @prepared_transactions.delete(transaction.id)
          @stats[:committed_count] += 1
          true
        end
      end

      def rollback_prepared(transaction)
        @lock.synchronize do
          prepared = @prepared_transactions[transaction.id]
          return false unless prepared
          
          # Write rollback record
          @transaction_manager.transaction_log.log_rollback(transaction)
          
          # Rollback changes
          rollback_changes(transaction)
          
          @prepared_transactions.delete(transaction.id)
          @stats[:rolled_back_count] += 1
          true
        end
      end

      def resolve_in_doubt
        @lock.synchronize do
          @prepared_transactions.each do |id, prepared|
            next unless prepared[:transaction].in_doubt?
            
            # Try to resolve by checking if commit was successful
            if can_commit?(prepared[:transaction])
              commit_prepared(prepared[:transaction])
            else
              rollback_prepared(prepared[:transaction])
            end
          end
        end
      end

      def async_commit(transaction)
        @lock.synchronize do
          @commit_queue << {
            transaction: transaction,
            added_at: Time.now
          }
        end
      end

      private

      def one_phase_commit(transaction)
        # Simple commit - write to log and apply changes
        @transaction_manager.transaction_log.log_commit(transaction)
        commit_changes(transaction)
        @stats[:committed_count] += 1
        true
      end

      def two_phase_commit(transaction)
        @stats[:two_phase_commits] += 1
        
        # Phase 1: Prepare
        unless prepare(transaction)
          return false
        end
        
        # Phase 2: Commit
        commit_prepared(transaction)
        
        true
      end

      def commit_changes(transaction)
        # Apply all changes
        transaction.modified_rows.each do |row_id, info|
          @transaction_manager.engine.update_row(
            info[:table],
            row_id,
            info[:new]
          )
        end
        
        # Update indexes
        if @transaction_manager.engine.respond_to?(:index_manager)
          transaction.modified_rows.each do |row_id, info|
            # Update index entries
            @transaction_manager.engine.index_manager.update_row(
              info[:table],
              info[:old],
              info[:new]
            )
          end
        end
      end

      def rollback_changes(transaction)
        # Rollback in reverse order
        transaction.modified_rows.each do |row_id, info|
          @transaction_manager.engine.update_row(
            info[:table],
            row_id,
            info[:old]
          )
        end
      end

      def can_commit?(transaction)
        # Check if all resources are available
        transaction.modified_rows.each do |row_id, info|
          # Check if no other transaction modified the same row
          @transaction_manager.active_transactions.each do |_, other|
            next if other.id == transaction.id
            if other.modified_rows.key?(row_id)
              return false
            end
          end
        end
        
        true
      end

      def start_commit_thread
        @commit_thread = Thread.new do
          loop do
            sleep(1)  # Process every second
            
            begin
              # Process commit queue
              while !@commit_queue.empty?
                entry = @commit_queue.shift
                commit(entry[:transaction])
              end
              
              # Resolve in-doubt transactions
              resolve_in_doubt
            rescue => e
              # Log error but continue
            end
          end
        end
      end

      def engine
        @transaction_manager.engine
      end
    end
  end
end