# frozen_string_literal: true

require "fileutils"
require "json"
require "zlib"
require "monitor"
require "digest"
require "pathname"
require_relative "../storage/engine"

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
        @lock = Monitor.new
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
        destination = options[:destination] || @engine&.data_dir
        raise ArgumentError, "Restore destination is required" unless destination
        FileUtils.mkdir_p(destination)

        # Restore data files
        files = metadata[:files] || []
        files.each do |file|
          src = manifest_file_path(backup_path, file)
          raise ArgumentError, "Invalid manifest file path: #{file}" unless src
          next unless File.exist?(src)

          # Determine destination
          dest = file.start_with?("wal/") ? File.join(destination, "wal") : destination
          FileUtils.mkdir_p(dest)

          destination_name = File.basename(file).sub(/\.gz\z/, "")
          dest_path = File.join(dest, destination_name)
          restore_file(src, dest_path)
        end

        # Restore schema
        schema_path = File.join(backup_path, "schema.sql")
        if File.exist?(schema_path) && @engine
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
        base_path = backup_path_for_name(base_backup)
        return { success: false, error: "Invalid base backup name" } unless base_path
        unless Dir.exist?(base_path)
          return { success: false, error: "Base backup not found" }
        end

        base_metadata = JSON.parse(File.read(File.join(base_path, "manifest.json")), symbolize_names: true)
        base_result = restore_full(base_path, base_metadata, options)
        return base_result unless base_result[:success]
        apply_delta(backup_path, metadata, options)

        { success: true, restored_from: metadata[:name], base: base_backup }
      end

      def restore_differential(backup_path, metadata, options)
        base_backup = metadata[:base_backup]
        unless base_backup
          return { success: false, error: "Base backup not specified" }
        end

        # Restore base backup first
        base_path = backup_path_for_name(base_backup)
        return { success: false, error: "Invalid base backup name" } unless base_path
        unless Dir.exist?(base_path)
          return { success: false, error: "Base backup not found" }
        end

        base_metadata = JSON.parse(File.read(File.join(base_path, "manifest.json")), symbolize_names: true)
        base_result = restore_full(base_path, base_metadata, options)
        return base_result unless base_result[:success]
        apply_delta(backup_path, metadata, options)

        { success: true, restored_from: metadata[:name], base: base_backup }
      end

      def restore_file(src, dest)
        if src.end_with?(".gz")
          decompress_file(src, dest)
        else
          FileUtils.cp(src, dest)
        end
      end

      def backup_path_for_name(name)
        value = name.to_s
        return nil if value.empty? || value != File.basename(value)

        root = File.expand_path(@config[:backup_dir] || "backups")
        path = File.expand_path(File.join(root, value))
        path.start_with?("#{root}#{File::SEPARATOR}") ? path : nil
      end

      def manifest_file_path(root_path, relative_path)
        relative = relative_path.to_s
        return nil if relative.empty? || Pathname.new(relative).absolute?

        root = File.expand_path(root_path)
        path = File.expand_path(File.join(root, relative))
        path.start_with?("#{root}#{File::SEPARATOR}") ? path : nil
      end

      def apply_delta(delta_path, metadata, options)
        changes_path = File.join(delta_path, "changes.json")
        return { success: false, error: "Delta changes file not found" } unless File.file?(changes_path)
        if metadata[:checksum] && Digest::SHA256.file(changes_path).hexdigest != metadata[:checksum]
          return { success: false, error: "Delta checksum mismatch" }
        end

        engine = @engine
        owned_engine = false
        if engine.nil?
          destination = options[:destination]
          database_file = Dir.glob(File.join(destination.to_s, "*.rdb")).first
          return { success: false, error: "Engine or restored database is required for delta restore" } unless database_file
          engine = Storage::Engine.new(database_file, auto_vacuum: false)
          owned_engine = true
        end
        changes = JSON.parse(File.read(changes_path), symbolize_names: true).fetch(:changes)
        changes.each { |change| apply_delta_change(engine, change) }
        { success: true }
      rescue StandardError => error
        { success: false, error: error.message }
      ensure
        engine&.close if owned_engine
      end

      def apply_delta_change(engine, change)
        table = change[:table_name] || change[:table]
        case change[:type].to_s
        when "insert"
          columns = engine.table_columns(table)
          values = (change[:values] || change[:data] || {}).each_with_object({}) { |(key, value), result| result[key.to_s] = value }
          engine.insert_row(table, columns, values)
        when "update"
          values = (change[:values] || change[:data] || {}).each_with_object({}) { |(key, value), result| result[key.to_s] = value }
          engine.update_row(table, change[:row_id], values, visibility_check: false)
        when "delete"
          engine.delete_row(table, change[:row_id], visibility_check: false)
        else
          raise ArgumentError, "Unsupported delta operation: #{change[:type]}"
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
