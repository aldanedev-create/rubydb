# frozen_string_literal: true

module RubyDB
  module Branching
    # Checkout - Handles branch checkout operations
    class Checkout
      attr_reader :stats

      def initialize(engine, branch_manager, config = {})
        @engine = engine
        @branch_manager = branch_manager
        @config = config
        @checkout_history = []
        @stats = {
          checkouts: 0,
          successful_checkouts: 0,
          failed_checkouts: 0,
          checkout_time_ms: 0,
          avg_checkout_time_ms: 0,
          last_checkout: nil
        }
        @lock = Mutex.new
        @max_history = config[:max_history] || 100
      end

      def checkout(branch_name, options = {})
        @lock.synchronize do
          start_time = Time.now
          @stats[:checkouts] += 1

          # Validate branch exists
          branch = @branch_manager.get_branch(branch_name)
          unless branch
            @stats[:failed_checkouts] += 1
            return { success: false, error: "Branch '#{branch_name}' not found" }
          end

          # Check if branch can be checked out
          if branch.locked? && !options[:force]
            @stats[:failed_checkouts] += 1
            return { success: false, error: "Branch '#{branch_name}' is locked" }
          end

          begin
            # Perform checkout
            result = perform_checkout(branch, options)

            if result[:success]
              # Update branch manager
              @branch_manager.checkout(branch_name)

              # Record history
              record_checkout(branch_name, options)

              @stats[:successful_checkouts] += 1
              @stats[:last_checkout] = Time.now

              elapsed_ms = (Time.now - start_time) * 1000
              @stats[:checkout_time_ms] += elapsed_ms
              @stats[:avg_checkout_time_ms] = @stats[:checkout_time_ms] / @stats[:successful_checkouts]
            else
              @stats[:failed_checkouts] += 1
            end

            result.merge(elapsed_ms: elapsed_ms)

          rescue => e
            @stats[:failed_checkouts] += 1
            { success: false, error: e.message }
          end
        end
      end

      def checkout_or_create(branch_name, options = {})
        @lock.synchronize do
          branch = @branch_manager.get_branch(branch_name)

          if branch
            checkout(branch_name, options)
          else
            # Create branch then checkout
            result = @branch_manager.create_branch(branch_name, options)
            if result[:success]
              checkout(branch_name, options)
            else
              result
            end
          end
        end
      end

      def checkout_latest(options = {})
        @lock.synchronize do
          # Find latest branch by creation time
          branches = @branch_manager.list_branches
          return { success: false, error: "No branches available" } if branches.empty?

          latest = branches.max_by { |b| b[:created_at] }
          checkout(latest[:name], options)
        end
      end

      def checkout_history
        @checkout_history.dup
      end

      def stats
        @lock.synchronize do
          @stats.merge({
            history_size: @checkout_history.size,
            max_history: @max_history
          })
        end
      end

      private

      def perform_checkout(branch, options)
        branch_name = branch.name

        # Get branch data
        branch_data = get_branch_data(branch_name)

        # Apply branch state to engine
        apply_branch_state(branch_data)

        # Update engine to branch head
        @engine.apply_branch_head(branch.head_lsn) if branch.head_lsn

        { success: true, branch_name: branch_name, head_lsn: branch.head_lsn }
      end

      def get_branch_data(branch_name)
        branch = @branch_manager.get_branch(branch_name)
        raise ArgumentError, "Branch '#{branch_name}' not found" unless branch
        snapshot = branch.respond_to?(:state_snapshot) ? branch.state_snapshot : nil
        changes = branch.respond_to?(:logical_changes) ? branch.logical_changes : branch.changes
        { base: snapshot, changes: changes }
      end

      def apply_branch_state(branch_data)
        unless @engine.respond_to?(:apply_branch_state)
          raise ArgumentError, "Branch checkout requires an engine state-application hook"
        end

        result = @engine.apply_branch_state(branch_data)
        raise ArgumentError, "Engine rejected branch state" if result == false
        result
      end

      def record_checkout(branch_name, options)
        entry = {
          branch_name: branch_name,
          timestamp: Time.now.iso8601,
          options: options
        }

        @checkout_history << entry

        if @checkout_history.size > @max_history
          @checkout_history.shift
        end
      end
    end
  end
end
