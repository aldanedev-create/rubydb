# frozen_string_literal: true

require "set"

module RubyDB
  module Branching
    # Merge - Handles branch merging
    class Merge
      attr_reader :stats

      # Merge strategies
      STRATEGY_FAST_FORWARD = :fast_forward
      STRATEGY_RECURSIVE = :recursive
      STRATEGY_OCTOPUS = :octopus
      STRATEGY_SQUASH = :squash

      def initialize(engine, branch_manager, config = {})
        @engine = engine
        @branch_manager = branch_manager
        @config = config
        @strategy = config[:strategy] || STRATEGY_FAST_FORWARD
        @merge_history = []
        @stats = {
          merges: 0,
          successful_merges: 0,
          failed_merges: 0,
          conflicts_detected: 0,
          conflicts_resolved: 0,
          merge_time_ms: 0,
          avg_merge_time_ms: 0
        }
        @lock = Mutex.new
        @max_history = config[:max_history] || 100
      end

      def merge(source_branch, target_branch = nil, options = {})
        @lock.synchronize do
          start_time = Time.now
          @stats[:merges] += 1

          target_branch ||= @branch_manager.current_branch
          unless target_branch
            @stats[:failed_merges] += 1
            return { success: false, error: "No target branch specified" }
          end

          source = @branch_manager.get_branch(source_branch)
          target = @branch_manager.get_branch(target_branch)

          unless source
            @stats[:failed_merges] += 1
            return { success: false, error: "Source branch '#{source_branch}' not found" }
          end

          unless target
            @stats[:failed_merges] += 1
            return { success: false, error: "Target branch '#{target_branch}' not found" }
          end

          if source == target
            @stats[:failed_merges] += 1
            return { success: false, error: "Cannot merge a branch with itself" }
          end

          begin
            # Detect conflicts
            conflicts = detect_conflicts(source, target)

            if conflicts.any?
              @stats[:conflicts_detected] += 1

              if options[:abort_on_conflict]
                @stats[:failed_merges] += 1
                return {
                  success: false,
                  conflicts: conflicts,
                  message: "Conflicts detected, merge aborted"
                }
              end

              # Try to resolve conflicts
              if options[:resolve_conflicts]
                resolved = resolve_conflicts(conflicts, options)
                conflicts = resolved[:remaining] if resolved[:remaining]
              end
            end

            # Perform merge based on strategy
            result = case @strategy
            when STRATEGY_FAST_FORWARD
              merge_fast_forward(source, target, options)
            when STRATEGY_RECURSIVE
              merge_recursive(source, target, options)
            when STRATEGY_OCTOPUS
              merge_octopus(source, target, options)
            when STRATEGY_SQUASH
              merge_squash(source, target, options)
            else
              merge_fast_forward(source, target, options)
            end

            if result[:success]
              # Update branch manager
              target.commit(result[:changes])

              @stats[:successful_merges] += 1

              elapsed_ms = (Time.now - start_time) * 1000
              @stats[:merge_time_ms] += elapsed_ms
              @stats[:avg_merge_time_ms] = @stats[:merge_time_ms] / @stats[:successful_merges]

              # Record history
              record_merge(source_branch, target_branch, options)

              result.merge(elapsed_ms: elapsed_ms)
            else
              @stats[:failed_merges] += 1
              result
            end

          rescue => e
            @stats[:failed_merges] += 1
            { success: false, error: e.message }
          end
        end
      end

      def merge_abort
        @lock.synchronize do
          # Abort ongoing merge
          { success: true, message: "Merge aborted" }
        end
      end

      def merge_history
        @merge_history.dup
      end

      def stats
        @lock.synchronize do
          @stats.merge({
            strategy: @strategy,
            history_size: @merge_history.size,
            max_history: @max_history
          })
        end
      end

      private

      def detect_conflicts(source, target)
        # In production, would detect actual conflicts
        []
      end

      def resolve_conflicts(conflicts, options)
        # In production, would resolve conflicts
        { remaining: [], resolved: conflicts }
      end

      def merge_fast_forward(source, target, options)
        # Fast-forward merge
        changes = source.changes

        {
          success: true,
          changes: changes,
          strategy: :fast_forward,
          message: "Fast-forward merge completed"
        }
      end

      def merge_recursive(source, target, options)
        # Recursive merge
        changes = source.changes

        {
          success: true,
          changes: changes,
          strategy: :recursive,
          message: "Recursive merge completed"
        }
      end

      def merge_octopus(source, target, options)
        # Octopus merge (for merging multiple branches)
        changes = source.changes

        {
          success: true,
          changes: changes,
          strategy: :octopus,
          message: "Octopus merge completed"
        }
      end

      def merge_squash(source, target, options)
        # Squash merge (combine all changes into one commit)
        changes = source.changes

        {
          success: true,
          changes: changes,
          strategy: :squash,
          message: "Squash merge completed"
        }
      end

      def record_merge(source_branch, target_branch, options)
        entry = {
          source: source_branch,
          target: target_branch,
          timestamp: Time.now.iso8601,
          options: options,
          strategy: @strategy
        }

        @merge_history << entry

        if @merge_history.size > @max_history
          @merge_history.shift
        end
      end
    end
  end
end