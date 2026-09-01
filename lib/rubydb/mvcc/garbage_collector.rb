# frozen_string_literal: true

module RubyDB
  module MVCC
    # GarbageCollector - Collects and removes garbage versions
    class GarbageCollector
      attr_reader :stats

      def initialize(version_store, visibility, config = {})
        @version_store = version_store
        @visibility = visibility
        @config = config
        @collection_interval = config[:interval] || 300  # 5 minutes
        @threshold = config[:threshold] || 0.2  # 20% garbage triggers collection
        @max_collect_per_run = config[:max_collect] || 10000
        @stats = {
          collections: 0,
          garbage_collected: 0,
          space_freed: 0,
          last_collection: nil,
          average_collected: 0
        }
        @lock = Mutex.new
        @running = false
        @gc_thread = nil
      end

      def start
        @lock.synchronize do
          return if @running

          @running = true
          @gc_thread = Thread.new do
            while @running
              sleep(@collection_interval)
              begin
                collect
              rescue => e
                # Log error but continue
                puts "GC error: #{e.message}"
              end
            end
          end
        end
      end

      def stop
        @lock.synchronize do
          @running = false
          @gc_thread&.kill
          @gc_thread = nil
        end
      end

      def collect
        @lock.synchronize do
          @stats[:collections] += 1
          start_time = Time.now

          collected = 0

          # Find garbage versions
          garbage = find_garbage

          # Remove garbage
          garbage.each do |version|
            # Check if version is still referenced
            if is_referenced?(version)
              next
            end

            # Remove the version
            @version_store.delete_version(version)
            @stats[:garbage_collected] += 1
            collected += 1

            break if collected >= @max_collect_per_run
          end

          # Update stats
          elapsed_ms = ((Time.now - start_time) * 1000).round(2)
          @stats[:last_collection] = {
            time: Time.now.iso8601,
            elapsed_ms: elapsed_ms,
            collected: collected,
            garbage_found: garbage.size
          }

          @stats[:average_collected] = @stats[:garbage_collected] / @stats[:collections].to_f

          collected
        end
      end

      def find_garbage
        garbage = []
        versions_by_row = @version_store.instance_variable_get(:@versions)

        versions_by_row.each do |row_id, versions|
          # Find versions that are garbage
          versions.each do |version|
            if is_garbage?(version)
              garbage << version
            end
          end
        end

        garbage
      end

      def is_garbage?(version)
        # Check if version is garbage based on rules

        # 1. Aborted versions are garbage
        return true if version.is_aborted

        # 2. Deleted versions that are old
        if version.is_deleted && version.is_committed
          # Check if there's a newer version
          versions = @version_store.get_all_versions(version.row_id)
          newer_versions = versions.select { |v| v.created_at > version.created_at }
          if newer_versions.any?
            return true
          end
        end

        # 3. Committed versions that are no longer referenced
        if version.is_committed && !version.is_deleted
          # Check if any active transaction needs this version
          if !has_references?(version)
            return true
          end
        end

        false
      end

      def is_referenced?(version)
        # Check if version is referenced by any active transaction
        # or is needed for rollback
        has_references?(version)
      end

      def has_references?(version)
        # Check if any active transaction might need this version
        # For simplicity, we check if there are any active versions
        # that reference this version as previous version
        versions_by_row = @version_store.instance_variable_get(:@versions)

        versions_by_row.each do |_, versions|
          versions.each do |v|
            if v.prev_version_id == version.version_id
              return true
            end
          end
        end

        false
      end

      def force_collect
        collect
      end

      def stats
        @lock.synchronize do
          @stats.merge({
            running: @running,
            interval: @collection_interval,
            threshold: @threshold,
            max_per_run: @max_collect_per_run,
            garbage_ratio: garbage_ratio
          })
        end
      end

      def garbage_ratio
        total = @version_store.version_count
        return 0.0 if total == 0

        # Estimate garbage count
        garbage = find_garbage
        garbage.size.to_f / total
      end

      def status
        @lock.synchronize do
          {
            running: @running,
            last_collection: @stats[:last_collection],
            total_collected: @stats[:garbage_collected],
            average_collected: @stats[:average_collected],
            garbage_ratio: garbage_ratio
          }
        end
      end
    end
  end
end