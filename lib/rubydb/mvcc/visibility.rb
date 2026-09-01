# frozen_string_literal: true

require "set"

module RubyDB
  module MVCC
    # Visibility - Determines visibility of versions to transactions
    class Visibility
      attr_reader :stats

      def initialize
        @visibility_cache = {}
        @stats = {
          cache_hits: 0,
          cache_misses: 0,
          visibility_checks: 0,
          cache_evictions: 0
        }
        @cache_size = 10000
        @lock = Mutex.new
      end

      def visible?(version, transaction_id, snapshot = nil)
        @lock.synchronize do
          @stats[:visibility_checks] += 1

          # Check cache
          cache_key = "#{version.version_id}:#{transaction_id}"
          if @visibility_cache.key?(cache_key)
            @stats[:cache_hits] += 1
            return @visibility_cache[cache_key]
          end

          result = check_visibility(version, transaction_id, snapshot)

          # Cache result
          if @visibility_cache.size >= @cache_size
            evict_oldest_cache_entry
          end

          @visibility_cache[cache_key] = result
          @stats[:cache_misses] += 1

          result
        end
      end

      def check_visibility(version, transaction_id, snapshot = nil)
        # Check if version is from the same transaction
        return true if version.transaction_id == transaction_id

        # Check snapshot
        if snapshot
          return snapshot.visible?(version, transaction_id)
        end

        # If not committed, invisible to others
        return false unless version.is_committed

        # Check if deleted
        return false if version.is_deleted && version.visibility == :deleted

        # Check commit visibility
        if version.commit_id
          return version.commit_id <= transaction_id
        end

        true
      end

      def clear_cache
        @lock.synchronize do
          @visibility_cache.clear
          @stats[:cache_evictions] += 1
        end
      end

      def cache_size
        @visibility_cache.size
      end

      def stats
        @lock.synchronize do
          @stats.merge({
            cache_size: @visibility_cache.size,
            hit_rate: hit_rate
          })
        end
      end

      private

      def hit_rate
        total = @stats[:cache_hits] + @stats[:cache_misses]
        return 0.0 if total == 0
        (@stats[:cache_hits].to_f / total * 100).round(2)
      end

      def evict_oldest_cache_entry
        # Remove first entry (oldest)
        if @visibility_cache.any?
          key = @visibility_cache.keys.first
          @visibility_cache.delete(key)
          @stats[:cache_evictions] += 1
        end
      end
    end
  end
end