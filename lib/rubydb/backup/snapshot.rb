# frozen_string_literal: true

require "fileutils"
require "time"
require "json"

module RubyDB
  module Backup
    # Snapshot - Creates point-in-time snapshots
    class Snapshot
      attr_reader :stats

      def initialize(engine, config = {})
        @engine = engine
        @config = config
        @snapshot_dir = config[:snapshot_dir] || "snapshots"
        @max_snapshots = config[:max_snapshots] || 10
        @retention_days = config[:retention_days] || 30
        @snapshots = {}
        @stats = {
          snapshots_created: 0,
          snapshots_restored: 0,
          snapshots_deleted: 0,
          total_size_bytes: 0,
          last_snapshot: nil
        }
        @lock = Mutex.new

        FileUtils.mkdir_p(@snapshot_dir)
        load_snapshots
      end

      def create_snapshot(name = nil)
        @lock.synchronize do
          start_time = Time.now
          snapshot_name = name || "snapshot_#{Time.now.strftime('%Y%m%d_%H%M%S')}"
          snapshot_path = File.join(@snapshot_dir, snapshot_name)

          if Dir.exist?(snapshot_path)
            return { success: false, error: "Snapshot already exists" }
          end

          begin
            # Create snapshot
            FileUtils.mkdir_p(snapshot_path)

            # Get current database state
            state = capture_database_state

            # Store snapshot metadata
            metadata = {
              name: snapshot_name,
              created_at: Time.now.iso8601,
              engine_version: RubyDB::VERSION,
              database_name: @engine.current_database_name,
              state: state,
              size: 0
            }

            # Create copy-on-write snapshot
            create_cow_snapshot(snapshot_path)

            # Write metadata
            File.write(File.join(snapshot_path, "snapshot.json"), JSON.generate(metadata))

            # Calculate size
            size = calculate_snapshot_size(snapshot_path)
            metadata[:size] = size

            # Update stats
            @snapshots[snapshot_name] = metadata
            @stats[:snapshots_created] += 1
            @stats[:total_size_bytes] += size
            @stats[:last_snapshot] = Time.now

            # Clean old snapshots
            clean_old_snapshots

            { success: true, snapshot_name: snapshot_name, metadata: metadata }

          rescue => e
            FileUtils.rm_rf(snapshot_path) if Dir.exist?(snapshot_path)
            { success: false, error: e.message }
          end
        end
      end

      def restore_snapshot(snapshot_name, options = {})
        @lock.synchronize do
          snapshot_path = File.join(@snapshot_dir, snapshot_name)
          unless Dir.exist?(snapshot_path)
            return { success: false, error: "Snapshot does not exist" }
          end

          metadata_path = File.join(snapshot_path, "snapshot.json")
          unless File.exist?(metadata_path)
            return { success: false, error: "Snapshot metadata not found" }
          end

          begin
            metadata = JSON.parse(File.read(metadata_path), symbolize_names: true)

            # Restore from snapshot
            restore_cow_snapshot(snapshot_path)

            @stats[:snapshots_restored] += 1

            { success: true, snapshot_name: snapshot_name, metadata: metadata }

          rescue => e
            { success: false, error: e.message }
          end
        end
      end

      def list_snapshots
        @lock.synchronize do
          @snapshots.values.sort_by { |s| s[:created_at] }.reverse
        end
      end

      def delete_snapshot(snapshot_name)
        @lock.synchronize do
          snapshot_path = File.join(@snapshot_dir, snapshot_name)
          unless Dir.exist?(snapshot_path)
            return { success: false, error: "Snapshot does not exist" }
          end

          size = calculate_snapshot_size(snapshot_path)
          FileUtils.rm_rf(snapshot_path)

          @snapshots.delete(snapshot_name)
          @stats[:snapshots_deleted] += 1
          @stats[:total_size_bytes] -= size

          { success: true }
        end
      end

      def stats
        @lock.synchronize do
          @stats.merge({
            snapshots: @snapshots.size,
            snapshot_dir: @snapshot_dir,
            max_snapshots: @max_snapshots
          })
        end
      end

      private

      def load_snapshots
        Dir.glob(File.join(@snapshot_dir, "snapshot_*")).each do |path|
          metadata_path = File.join(path, "snapshot.json")
          next unless File.exist?(metadata_path)

          begin
            metadata = JSON.parse(File.read(metadata_path), symbolize_names: true)
            @snapshots[metadata[:name]] = metadata
          rescue
            # Skip corrupted snapshots
          end
        end
      end

      def capture_database_state
        {
          tables: @engine.list_tables,
          sequences: @engine.list_sequences,
          current_lsn: @engine.current_lsn,
          wal_position: @engine.wal_position,
          active_transactions: @engine.active_transactions
        }
      end

      def create_cow_snapshot(snapshot_path)
        # In production, would create copy-on-write snapshot
        # For now, create hard links to data files
        data_files = @engine.data_files rescue []
        data_files.each do |file|
          dest = File.join(snapshot_path, File.basename(file))
          File.link(file, dest) rescue FileUtils.cp(file, dest)
        end
      end

      def restore_cow_snapshot(snapshot_path)
        # In production, would restore from copy-on-write snapshot
        data_files = Dir.glob(File.join(snapshot_path, "*.rdb"))
        data_files.each do |file|
          dest = File.join(@engine.data_dir, File.basename(file))
          FileUtils.cp(file, dest)
        end
      end

      def calculate_snapshot_size(snapshot_path)
        Dir.glob(File.join(snapshot_path, "**/*")).sum do |f|
          File.size(f) if File.file?(f)
        end || 0
      end

      def clean_old_snapshots
        snapshots = list_snapshots

        # Remove by retention days
        cutoff = Time.now - @retention_days * 24 * 60 * 60
        snapshots.select { |s| Time.parse(s[:created_at]) < cutoff }.each do |s|
          delete_snapshot(s[:name])
        end

        # Remove by count
        snapshots = list_snapshots
        if snapshots.size > @max_snapshots
          snapshots.last(snapshots.size - @max_snapshots).each do |s|
            delete_snapshot(s[:name])
          end
        end
      end
    end
  end
end