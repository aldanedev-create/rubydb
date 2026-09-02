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
        @last_merge = nil
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

          target_branch ||= if @branch_manager.respond_to?(:current_branch_name)
                              @branch_manager.current_branch_name
                            else
                              @branch_manager.current_branch&.name
                            end
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
              if conflicts.any?
                @stats[:failed_merges] += 1
                return { success: false, conflicts: conflicts, message: "Unresolved conflicts" }
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
              previous_changes = target.logical_changes
              merge_changes = Array(result[:changes])
              merged_changes = previous_changes + merge_changes
              if @engine && @branch_manager.respond_to?(:current_branch_name) &&
                  @branch_manager.current_branch_name == target_branch &&
                  @engine.respond_to?(:apply_branch_state)
                begin
                  @engine.apply_branch_state(base: target.state_snapshot, changes: merged_changes)
                rescue => error
                  @stats[:failed_merges] += 1
                  return { success: false, error: "Unable to apply merged state: #{error.message}" }
                end
              end

              # Update branch manager
              target.merge_changes(merge_changes)
              @branch_manager.persist! if @branch_manager.respond_to?(:persist!)
              @last_merge = {
                source: source_branch,
                target: target_branch,
                previous_changes: previous_changes,
                merged_count: merge_changes.size
              }

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
          merge = @last_merge
          return { success: false, error: "No merge to abort" } unless merge

          target = @branch_manager.get_branch(merge[:target])
          unless target
            return { success: false, error: "Target branch '#{merge[:target]}' not found" }
          end

          target.rollback(merge[:merged_count]) if merge[:merged_count].positive?
          if @engine && @branch_manager.respond_to?(:current_branch_name) &&
              @branch_manager.current_branch_name == merge[:target] &&
              @engine.respond_to?(:apply_branch_state)
            @engine.apply_branch_state(base: target.state_snapshot, changes: merge[:previous_changes])
          end
          @branch_manager.persist! if @branch_manager.respond_to?(:persist!)
          @merge_history.pop
          @last_merge = nil

          { success: true, target: merge[:target], reverted_changes: merge[:merged_count] }
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
        target_changes = target.respond_to?(:logical_changes) ? target.logical_changes : target.changes
        source_changes = source.respond_to?(:logical_changes) ? source.logical_changes : source.changes
        target_keys = target_changes.map { |change| change_key(change) }
        source_changes.filter_map do |change|
          next unless target_keys.include?(change_key(change))
          other = target_changes.find { |candidate| change_key(candidate) == change_key(change) }
          { key: change_key(change), source: change, target: other } unless other == change
        end
      end

      def resolve_conflicts(conflicts, options)
        resolver = options[:conflict_resolver]
        raise ArgumentError, "conflict_resolver is required" unless resolver.respond_to?(:call)
        remaining = conflicts.filter_map { |conflict| resolver.call(conflict) ? nil : conflict }
        { remaining: remaining }
      end

      def change_key(change)
        [change[:table] || change["table"], change[:row_id] || change["row_id"], change[:column] || change["column"]]
      end

      def merge_fast_forward(source, target, options)
        # Fast-forward merge
        changes = source.respond_to?(:logical_changes) ? source.logical_changes : source.changes

        {
          success: true,
          changes: changes,
          strategy: :fast_forward,
          message: "Fast-forward merge completed"
        }
      end

      def merge_recursive(source, target, options)
        # Recursive merge
        changes = source.respond_to?(:logical_changes) ? source.logical_changes : source.changes

        {
          success: true,
          changes: changes,
          strategy: :recursive,
          message: "Recursive merge completed"
        }
      end

      def merge_octopus(source, target, options)
        # Octopus merge (for merging multiple branches)
        changes = source.respond_to?(:logical_changes) ? source.logical_changes : source.changes

        {
          success: true,
          changes: changes,
          strategy: :octopus,
          message: "Octopus merge completed"
        }
      end

      def merge_squash(source, target, options)
        # Squash merge (combine all changes into one commit)
        changes = source.respond_to?(:logical_changes) ? source.logical_changes : source.changes

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
