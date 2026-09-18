# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "securerandom"

module RubyDB
  module Storage
    # Creates a validated snapshot manifest for the Go accelerator. The
    # default is a lock-protected read of the already-flushed live file;
    # operators can opt into a detached copy when they need one. Ruby remains
    # responsible for locking, WAL durability, catalog state, and MVCC
    # eligibility.
    class SnapshotReader
      FORMAT_VERSION = 1

      def initialize(engine)
        @engine = engine
        @directory = "#{engine.path}.accelerator-snapshots"
        @lock = Mutex.new
        @active_paths = {}
      end

      def with_snapshot
        snapshot = create
        begin
          yield snapshot
        ensure
          release(snapshot)
        end
      end

      def close
        @lock.synchronize do
          @active_paths.keys.each { |path| delete_file(path) }
          @active_paths.clear
          Dir.rmdir(@directory) if Dir.exist?(@directory) && Dir.empty?(@directory)
        end
      end

      private

      def create
        source = File.expand_path(@engine.path)
        raise StorageError, "Cannot create accelerator snapshot: database file is missing" unless File.file?(source)

        # Engine#with_accelerator_snapshot holds the engine lock for the whole
        # yield, including the Go read. In that guarded section the live file
        # is already flushed and no Ruby writer can mutate it, so copying the
        # complete database before every read only adds latency and doubles
        # the storage I/O. Keep an opt-out copy mode for operators that need a
        # detached file, but make the lock-protected direct path the default.
        return direct_manifest(source) if direct_snapshot?

        FileUtils.mkdir_p(@directory)
        destination = File.join(@directory, "snapshot-#{Process.pid}-#{SecureRandom.hex(12)}.db")
        FileUtils.copy_file(source, destination, true)
        File.open(destination, "r+b") do |file|
          file.flush
          file.fsync
        end

        snapshot = manifest_for(
          destination,
          snapshot_id: File.basename(destination, ".db"),
          file_sha256: Digest::SHA256.file(destination).hexdigest,
          temporary: true
        )
        @lock.synchronize { @active_paths[destination] = true }
        snapshot
      # Remove a partially copied snapshot even when the caller is interrupted.
      # rubocop:disable Lint/RescueException
      rescue Exception
        delete_file(destination) if destination
        raise
        # rubocop:enable Lint/RescueException
      end

      def direct_manifest(source)
        manifest_for(
          source,
          snapshot_id: "live-#{Process.pid}-#{SecureRandom.hex(8)}",
          file_sha256: nil,
          temporary: false
        )
      end

      def manifest_for(path, snapshot_id:, file_sha256:, temporary:)
        {
          format_version: FORMAT_VERSION,
          snapshot_id: snapshot_id,
          snapshot_path: File.expand_path(path),
          page_size: @engine.storage_manager.page_size,
          page_count: @engine.storage_manager.file_manager.num_pages,
          file_sha256: file_sha256,
          tables: table_manifest,
          hidden_row_ids: @engine.accelerator_snapshot_hidden_row_ids,
          temporary: temporary
        }
      end

      def direct_snapshot?
        accelerator_config = @engine.config[:accelerator] || @engine.config["accelerator"] || {}
        configured = accelerator_config[:direct_snapshot] || accelerator_config["direct_snapshot"]
        configured = ENV.fetch("RUBYDB_ACCELERATOR_DIRECT_SNAPSHOT", "on") if configured.nil?
        !%w[off false 0].include?(configured.to_s.downcase)
      end

      def table_manifest
        @engine.table_metadata.each_with_object({}) do |(table_name, metadata), tables|
          columns = Array(metadata[:columns]).map do |column|
            {
              name: column.name.to_s,
              type: column.type_class.to_s,
              nullable: column.nullable?,
              default: json_value(column.default)
            }
          end
          indexes = Array(@engine.index_manager&.get_indexes_for_table(table_name)).filter_map do |index|
            next unless index.type.to_sym == :btree && index.respond_to?(:snapshot_entries)

            {
              name: index.name.to_s,
              type: index.type.to_s,
              columns: index.columns.map(&:to_s),
              unique: index.unique,
              entries: index.snapshot_entries.map do |entry|
                {key: json_value(entry[:key]), row_id: entry[:value].to_i}
              end
            }
          end

          tables[table_name.to_s] = {
            pages: Array(@engine.table_pages_for_snapshot(table_name)).map(&:to_i),
            columns: columns,
            indexes: indexes,
            row_count: metadata[:row_count].to_i
          }
        end
      end

      def json_value(value)
        JSON.parse(JSON.generate(value))
      rescue
        nil
      end

      def release(snapshot)
        path = snapshot && snapshot[:snapshot_path]
        return unless path && snapshot[:temporary]

        @lock.synchronize do
          @active_paths.delete(path)
          delete_file(path)
          Dir.rmdir(@directory) if Dir.exist?(@directory) && Dir.empty?(@directory)
        end
      end

      def delete_file(path)
        File.delete(path) if path && File.file?(path)
      rescue SystemCallError
        nil
      end
    end
  end
end
