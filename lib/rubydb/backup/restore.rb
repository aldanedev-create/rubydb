# frozen_string_literal: true

require "fileutils"
require "json"
require "zlib"

module RubyDB
  module Backup
    # Restore - Restores database from backups
    class Restore
      attr_reader :stats

      def initialize(engine, config = {})
        @engine = engine
        @config = config
        @stats = {
          restores: 0,
          successful_restores: 0,
          failed_restores: 0,
          total_time_ms: 0,
          avg_time_ms: 0,
          last_restore: nil
        }
        @lock = Mutex.new
        @incremental_restores = {}
      end

      def restore(backup_path, options = {})
        @lock.synchronize do
          start_time = Time.now
          @stats[:restores] += 1

          unless Dir.exist?(backup_path)
            return { success: false, error: "Backup path does not exist" }
          end

          manifest_path = File.join(backup_path, "manifest.json")
          unless File.exist?(manifest_path)
            return { success: false, error: "Manifest not found" }
          end

          begin
            metadata = JSON.parse(File.read(manifest_path), symbolize_names: true)

            # Validate backup type
            backup_type = metadata[:type]

            # Perform restore based on type
            result = case backup_type
            when Backup::TYPE_FULL
              restore_full(backup_path, metadata, options)
            when Backup::TYPE_INCREMENTAL
              restore_incremental(backup_path, metadata, options)
            when Backup::TYPE_DIFFERENTIAL
              restore_differential(backup_path, metadata, options)
            else
              restore_full(backup_path, metadata, options)
            end

            if result[:success]
              @stats[:successful_restores] += 1
              @stats[:last_restore] = Time.now

              elapsed_ms = (Time.now - start_time) * 1000
              @stats[:total_time_ms] += elapsed_ms
              @stats[:avg_time_ms] = @stats[:total_time_ms] / @stats[:successful_restores]
            else
              @stats[:failed_restores] += 1
            end

            result.merge(elapsed_ms: (Time.now - start_time) * 1000)

          rescue => e
            @stats[:failed_restores] += 1
            { success: false, error: e.message }
          end
        end
      end

      def restore_latest(options = {})
        backups = list_available_backups
        return { success: false, error: "No backups available" } if backups.empty?

        latest = backups.first
        restore(latest[:path], options)
      end

      def restore_point_in_time(time, options = {})
        backups = list_available_backups
        return { success: false, error: "No backups available" } if backups.empty?

        # Find the closest backup before the target time
        target = Time.parse(time)
        candidates = backups.select do |b|
          Time.parse(b[:created_at]) <= target
        end

        if candidates.empty?
          return { success: false, error: "No backup before the specified time" }
        end

        backup = candidates.first
        restore(backup[:path], options.merge(point_in_time: time))
      end

      def list_available_backups
        backups = []
        backup_dir = @config[:backup_dir] || "backups"
        Dir.glob(File.join(backup_dir, "backup_*")).each do |path|
          manifest_path = File.join(path, "manifest.json")
          next unless File.exist?(manifest_path)

          begin
            metadata = JSON.parse(File.read(manifest_path), symbolize_names: true)
            backups << metadata.merge(path: path)
          rescue
            # Skip corrupted manifests
          end
        end

        backups.sort_by { |b| b[:created_at] }.reverse
      end

      def stats
        @lock.synchronize do
          @stats.merge({
            incremental_restores: @incremental_restores.size
          })
        end
      end

      private

      def restore_full(backup_path, metadata, options)
        # Restore data files
        files = metadata[:files] || []
        files.each do |file|
          src = File.join(backup_path, file)
          next unless File.exist?(src)

          # Determine destination
          dest = if file.start_with?("wal/")
            @engine.wal_dir
          else
            @engine.data_dir
          end

          dest_path = File.join(dest, File.basename(file))
          restore_file(src, dest_path)
        end

        # Restore schema
        schema_path = File.join(backup_path, "schema.sql")
        if File.exist?(schema_path)
          schema = File.read(schema_path)
          @engine.execute_schema(schema)
        end

        { success: true, restored_from: metadata[:name] }
      end

      def restore_incremental(backup_path, metadata, options)
        base_backup = metadata[:base_backup]
        unless base_backup
          return { success: false, error: "Base backup not specified" }
        end

        # Restore base backup first
        base_path = File.join(@config[:backup_dir], base_backup)
        unless Dir.exist?(base_path)
          return { success: false, error: "Base backup not found" }
        end

        restore_full(base_path, metadata, options)

        # Then apply incremental changes
        restore_full(backup_path, metadata, options)

        { success: true, restored_from: metadata[:name], base: base_backup }
      end

      def restore_differential(backup_path, metadata, options)
        base_backup = metadata[:base_backup]
        unless base_backup
          return { success: false, error: "Base backup not specified" }
        end

        # Restore base backup first
        base_path = File.join(@config[:backup_dir], base_backup)
        unless Dir.exist?(base_path)
          return { success: false, error: "Base backup not found" }
        end

        restore_full(base_path, metadata, options)

        # Then apply differential changes
        restore_full(backup_path, metadata, options)

        { success: true, restored_from: metadata[:name], base: base_backup }
      end

      def restore_file(src, dest)
        if src.end_with?(".gz")
          decompress_file(src, dest)
        else
          FileUtils.cp(src, dest)
        end
      end

      def decompress_file(src, dest)
        Zlib::GzipReader.open(src) do |gz|
          File.open(dest, "wb") do |file|
            while chunk = gz.read(10 * 1024 * 1024)
              file.write(chunk)
            end
          end
        end
      end
    end
  end
end