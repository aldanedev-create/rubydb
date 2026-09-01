# frozen_string_literal: true

module RubyDB
  module MVCC
    # Vacuum - Manages cleanup of old versions and reclaims space
    class Vacuum
      attr_reader :stats

      def initialize(version_store, config = {})
        @version_store = version_store
        @config = config
        @vacuum_interval = config[:interval] || 60  # seconds
        @max_versions_per_row = config[:max_versions] || 100
        @min_age = config[:min_age] || 3600  # 1 hour
        @batch_size = config[:batch_size] || 1000
        @threshold = config[:threshold] || 0.3  # 30% of max versions
        @stats = {
          vacuum_runs: 0,
          versions_removed: 0,
          rows_compacted: 0,
          space_reclaimed: 0,
          last_vacuum: nil,
          average_removed_per_run: 0
        }
        @lock = Mutex.new
        @running = false
        @vacuum_thread = nil
      end

      def start
        @lock.synchronize do
          return if @running

          @running = true
          @vacuum_thread = Thread.new do
            while @running
              sleep(@vacuum_interval)
              begin
                run
              rescue => e
                # Log error but continue
                puts "Vacuum error: #{e.message}"
              end
            end
          end
        end
      end

      def stop
        @lock.synchronize do
          @running = false
          @vacuum_thread&.kill
          @vacuum_thread = nil
        end
      end

      def run
        @lock.synchronize do
          @stats[:vacuum_runs] += 1
          start_time = Time.now

          # Remove old versions
          removed = vacuum_versions

          # Compact version chains
          compacted = compact_version_chains

          # Update stats
          elapsed_ms = ((Time.now - start_time) * 1000).round(2)
          @stats[:last_vacuum] = {
            time: Time.now.iso8601,
            elapsed_ms: elapsed_ms,
            removed: removed,
            compacted: compacted
          }

          @stats[:versions_removed] += removed
          @stats[:rows_compacted] += compacted
          @stats[:average_removed_per_run] = @stats[:versions_removed] / @stats[:vacuum_runs].to_f

          { removed: removed, compacted: compacted }
        end
      end

      def vacuum_versions
        removed = 0
        batch_removed = 0

        # Get rows with excessive versions
        rows = @version_store.instance_variable_get(:@versions)
        candidates = rows.select do |_, versions|
          versions.size > @max_versions_per_row * @threshold
        end

        candidates.each do |row_id, versions|
          # Calculate how many to remove
          remove_count = versions.size - @max_versions_per_row
          next if remove_count <= 0

          # Remove oldest versions
          remove_count.times do
            version = versions.shift
            if version && version.is_committed && !version.is_deleted
              # Check age
              if Time.now - version.created_at > @min_age
                @version_store.instance_variable_get(:@version_map).delete(version.version_id)
                removed += 1
                batch_removed += 1
              end
            end
            break if batch_removed >= @batch_size
          end

          break if batch_removed >= @batch_size
        end

        removed
      end

      def compact_version_chains
        compacted = 0
        rows = @version_store.instance_variable_get(:@versions)

        rows.each do |row_id, versions|
          next if versions.size <= 1

          # Check if there are gaps or holes in the chain
          # Remove versions with no data (deleted, aborted)
          original_size = versions.size
          versions.delete_if do |version|
            version.is_deleted || version.is_aborted
          end

          if versions.size < original_size
            compacted += 1
          end

          # Update next_version_id links
          versions.each_with_index do |version, idx|
            if idx < versions.size - 1
              version.instance_variable_set(:@next_version_id, versions[idx + 1].version_id)
            else
              version.instance_variable_set(:@next_version_id, nil)
            end
          end
        end

        compacted
      end

      def force_run
        run
      end

      def stats
        @lock.synchronize do
          @stats.merge({
            running: @running,
            interval: @vacuum_interval,
            threshold: @threshold,
            max_versions: @max_versions_per_row,
            min_age: @min_age
          })
        end
      end

      def status
        @lock.synchronize do
          {
            running: @running,
            last_vacuum: @stats[:last_vacuum],
            total_removed: @stats[:versions_removed],
            total_compacted: @stats[:rows_compacted],
            average_removed: @stats[:average_removed_per_run]
          }
        end
      end
    end
  end
end