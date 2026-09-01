# frozen_string_literal: true

require "set"
require "json"

module RubyDB
  module MVCC
    # VersionStore - Stores and manages all versions of rows
    class VersionStore
      attr_reader :stats, :version_count, :row_count

      def initialize(config = {})
        @versions = {}  # row_id => [versions]
        @version_map = {}  # version_id => version
        @active_versions = Set.new
        @stats = {
          versions_created: 0,
          versions_committed: 0,
          versions_aborted: 0,
          versions_deleted: 0,
          versions_pruned: 0,
          cache_hits: 0,
          cache_misses: 0
        }
        @version_count = 0
        @row_count = 0
        @max_versions_per_row = config[:max_versions_per_row] || 100
        @lock = Mutex.new
        @persistence_path = config[:persistence_path]
        @dirty = false
      end

      def create_version(row_id, data, transaction_id)
        @lock.synchronize do
          # Get current latest version
          versions = @versions[row_id] || []
          prev_version_id = versions.last&.version_id

          # Create new version
          version = Version.new(row_id, data, transaction_id, prev_version_id)

          # Store version
          @versions[row_id] ||= []
          @versions[row_id] << version
          @version_map[version.version_id] = version

          # Update active versions
          @active_versions.add(version.version_id)

          @version_count += 1
          @row_count = @versions.size
          @stats[:versions_created] += 1
          @dirty = true

          version
        end
      end

      def commit_version(version, commit_id = nil)
        @lock.synchronize do
          version.commit(commit_id)
          @active_versions.delete(version.version_id)
          @stats[:versions_committed] += 1
          @dirty = true
        end
      end

      def abort_version(version)
        @lock.synchronize do
          version.abort
          @active_versions.delete(version.version_id)

          # Remove from version chain if it was the latest
          versions = @versions[version.row_id]
          if versions && versions.last&.version_id == version.version_id
            versions.pop
            @version_map.delete(version.version_id)
          end

          @stats[:versions_aborted] += 1
          @dirty = true
        end
      end

      def get_latest_version(row_id, transaction_id = nil, snapshot = nil)
        @lock.synchronize do
          # Check cache for snapshot
          cache_key = "#{row_id}:#{transaction_id}:#{snapshot&.id}"

          versions = @versions[row_id]
          return nil unless versions

          # Get the latest committed version visible to transaction
          versions.reverse_each do |version|
            if snapshot
              if version.visible_to?(transaction_id, snapshot)
                @stats[:cache_hits] += 1
                return version
              end
            elsif version.is_committed && !version.is_deleted
              # Check if version is committed before transaction started
              if version.commit_id && transaction_id && version.commit_id <= transaction_id
                @stats[:cache_hits] += 1
                return version
              end
            end
          end

          @stats[:cache_misses] += 1
          nil
        end
      end

      def get_version_at_time(row_id, time)
        @lock.synchronize do
          versions = @versions[row_id]
          return nil unless versions

          # Find version that was active at the given time
          versions.reverse_each do |version|
            if version.created_at <= time
              return version
            end
          end

          nil
        end
      end

      def get_all_versions(row_id)
        @lock.synchronize do
          @versions[row_id] || []
        end
      end

      def get_version(version_id)
        @lock.synchronize do
          @version_map[version_id]
        end
      end

      def delete_version(version)
        @lock.synchronize do
          version.mark_deleted
          @active_versions.delete(version.version_id)
          @stats[:versions_deleted] += 1
          @dirty = true
        end
      end

      def prune_versions(row_id, keep_count = nil)
        @lock.synchronize do
          versions = @versions[row_id]
          return 0 unless versions

          keep_count ||= @max_versions_per_row
          pruned = 0

          # Remove old versions (keeping the most recent ones)
          while versions.size > keep_count
            old_version = versions.shift
            next unless old_version

            # Only prune committed versions that are not active
            if old_version.is_committed && !@active_versions.include?(old_version.version_id)
              @version_map.delete(old_version.version_id)
              @stats[:versions_pruned] += 1
              pruned += 1
            else
              # Can't prune active versions, move to end
              versions << old_version
              break
            end
          end

          @dirty = true if pruned > 0
          pruned
        end
      end

      def active_version_count
        @active_versions.size
      end

      def prune_all(max_versions = nil)
        @lock.synchronize do
          total_pruned = 0
          @versions.keys.each do |row_id|
            total_pruned += prune_versions(row_id, max_versions)
          end
          total_pruned
        end
      end

      def vacuum
        @lock.synchronize do
          # Remove versions that are no longer needed
          removed = 0
          @versions.each do |row_id, versions|
            # Remove aborted versions
            versions.delete_if do |version|
              if version.is_aborted
                @version_map.delete(version.version_id)
                removed += 1
                true
              else
                false
              end
            end

            # Remove empty arrays
            if versions.empty?
              @versions.delete(row_id)
            end
          end

          @row_count = @versions.size
          @stats[:versions_pruned] += removed
          @dirty = true if removed > 0
          removed
        end
      end

      def serialize
        @lock.synchronize do
          data = {
            versions: {},
            version_count: @version_count,
            row_count: @row_count,
            active_versions: @active_versions.to_a,
            timestamp: Time.now.iso8601
          }

          @versions.each do |row_id, versions|
            data[:versions][row_id] = versions.map do |v|
              {
                row_id: v.row_id,
                version_id: v.version_id,
                created_at: v.created_at.iso8601,
                transaction_id: v.transaction_id,
                prev_version_id: v.prev_version_id,
                is_committed: v.is_committed,
                is_aborted: v.is_aborted,
                is_deleted: v.is_deleted,
                commit_id: v.commit_id,
                visibility: v.visibility,
                data: v.data
              }
            end
          end

          JSON.generate(data)
        end
      end

      def deserialize(json_data)
        @lock.synchronize do
          data = JSON.parse(json_data, symbolize_names: true)

          @versions.clear
          @version_map.clear
          @active_versions.clear

          data[:versions].each do |row_id, versions_data|
            @versions[row_id] = versions_data.map do |v_data|
              version = Version.new(
                v_data[:row_id],
                v_data[:data],
                v_data[:transaction_id],
                v_data[:prev_version_id]
              )
              version.instance_variable_set(:@version_id, v_data[:version_id])
              version.instance_variable_set(:@created_at, Time.parse(v_data[:created_at]))
              version.instance_variable_set(:@is_committed, v_data[:is_committed])
              version.instance_variable_set(:@is_aborted, v_data[:is_aborted])
              version.instance_variable_set(:@is_deleted, v_data[:is_deleted])
              version.instance_variable_set(:@commit_id, v_data[:commit_id])
              version.instance_variable_set(:@visibility, v_data[:visibility].to_sym)

              @version_map[version.version_id] = version
              version
            end
          end

          @version_count = data[:version_count] || 0
          @row_count = data[:row_count] || 0
          @active_versions = Set.new(data[:active_versions] || [])
          @dirty = false
        end
      end

      def persist
        return unless @persistence_path && @dirty

        @lock.synchronize do
          File.write(@persistence_path, serialize)
          @dirty = false
        end
      end

      def load
        return unless @persistence_path && File.exist?(@persistence_path)

        @lock.synchronize do
          json_data = File.read(@persistence_path)
          deserialize(json_data)
        end
      end

      def stats
        @lock.synchronize do
          @stats.merge({
            version_count: @version_count,
            row_count: @row_count,
            active_versions: @active_versions.size,
            rows_with_versions: @versions.size,
            dirty: @dirty
          })
        end
      end

      def inspect
        "#<VersionStore versions=#{@version_count} rows=#{@row_count} active=#{@active_versions.size}>"
      end
    end
  end
end