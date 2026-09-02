# frozen_string_literal: true

require "fileutils"
require "time"
require "json"
require "digest"
require "monitor"

module RubyDB
  module Backup
    class SnapshotError < StandardError; end unless const_defined?(:SnapshotError)
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
        @lock = Monitor.new

        FileUtils.mkdir_p(@snapshot_dir)
        load_snapshots
      end

      def create_snapshot(name = nil)
        @lock.synchronize do
          start_time = Time.now
          snapshot_name = name || "snapshot_#{Time.now.strftime('%Y%m%d_%H%M%S')}"
          snapshot_path = snapshot_path_for_name(snapshot_name)
          return { success: false, error: "Invalid snapshot name" } unless snapshot_path

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
            metadata[:files] = snapshot_files(snapshot_path).to_h do |file|
              [File.basename(file), Digest::SHA256.file(file).hexdigest]
            end
            File.write(File.join(snapshot_path, "snapshot.json"), JSON.generate(metadata))

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
          snapshot_path = snapshot_path_for_name(snapshot_name)
          return { success: false, error: "Invalid snapshot name" } unless snapshot_path

          unless Dir.exist?(snapshot_path)
            return { success: false, error: "Snapshot does not exist" }
          end

          metadata_path = File.join(snapshot_path, "snapshot.json")
          unless File.exist?(metadata_path)
            return { success: false, error: "Snapshot metadata not found" }
          end

          begin
            metadata = JSON.parse(File.read(metadata_path), symbolize_names: true)
            verify_snapshot!(snapshot_path, metadata)

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
          snapshot_path = snapshot_path_for_name(snapshot_name)
          return { success: false, error: "Invalid snapshot name" } unless snapshot_path

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

      def snapshot_path_for_name(snapshot_name)
        name = snapshot_name.to_s
        return nil if name.empty? || name != File.basename(name)

        root = File.expand_path(@snapshot_dir)
        path = File.expand_path(File.join(root, name))
        path == root || path.start_with?("#{root}#{File::SEPARATOR}") ? path : nil
      end

      def load_snapshots
        Dir.glob(File.join(@snapshot_dir, "*")).each do |path|
          next unless Dir.exist?(path)
          metadata_path = File.join(path, "snapshot.json")
          next unless File.exist?(metadata_path)

          begin
            metadata = JSON.parse(File.read(metadata_path), symbolize_names: true)
            @snapshots[metadata[:name]] = metadata
          rescue
            raise SnapshotError, "Invalid snapshot metadata: #{metadata_path}"
          end
        end
      end

      def capture_database_state
        {
          tables: @engine.list_tables,
          sequences: @engine.respond_to?(:list_sequences) ? @engine.list_sequences : [],
          current_lsn: @engine.respond_to?(:current_lsn) ? @engine.current_lsn : nil,
          wal_position: @engine.respond_to?(:wal_position) ? @engine.wal_position : nil,
          active_transactions: @engine.respond_to?(:active_transactions) ? @engine.active_transactions : []
        }
      end

      def create_cow_snapshot(snapshot_path)
        data_files = @engine.respond_to?(:data_files) ? @engine.data_files : []
        raise SnapshotError, "Engine returned no data files" if data_files.empty?
        data_files.each do |file|
          dest = File.join(snapshot_path, File.basename(file))
          begin
            File.link(file, dest)
          rescue Errno::EEXIST
            raise
          rescue SystemCallError
            FileUtils.cp(file, dest)
          end
          raise SnapshotError, "Snapshot file was not created: #{dest}" unless File.file?(dest)
        end
      end

      def restore_cow_snapshot(snapshot_path)
        metadata = JSON.parse(File.read(File.join(snapshot_path, "snapshot.json")), symbolize_names: true)
        verify_snapshot!(snapshot_path, metadata)
        data_files = snapshot_files(snapshot_path)
        data_files.each do |file|
          dest = File.join(@engine.data_dir, File.basename(file))
          FileUtils.cp(file, dest)
          raise SnapshotError, "Snapshot restore failed: #{dest}" unless FileUtils.compare_file(file, dest)
        end
        @engine.reload_from_disk if @engine.respond_to?(:reload_from_disk)
      end

      def snapshot_files(snapshot_path)
        Dir.glob(File.join(snapshot_path, "*")).select { |file| File.file?(file) && File.basename(file) != "snapshot.json" }
      end

      def verify_snapshot!(snapshot_path, metadata)
        files = metadata[:files]
        raise SnapshotError, "Snapshot has no file manifest" unless files.is_a?(Hash) && files.any?
        files.each do |name, checksum|
          file = File.join(snapshot_path, name.to_s)
          unless File.file?(file) && Digest::SHA256.file(file).hexdigest == checksum
            raise SnapshotError, "Snapshot checksum mismatch: #{name}"
          end
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
