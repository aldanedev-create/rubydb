# frozen_string_literal: true

require "fileutils"
require "time"
require "json"
require "zlib"
require "digest"

module RubyDB
  module Backup
    # Backup - Creates database backups
    class Backup
      attr_reader :config, :stats

      # Backup types
      TYPE_FULL = :full
      TYPE_INCREMENTAL = :incremental
      TYPE_DIFFERENTIAL = :differential

      # Backup formats
      FORMAT_PLAIN = :plain
      FORMAT_COMPRESSED = :compressed
      FORMAT_ENCRYPTED = :encrypted

      def initialize(engine, config = {})
        @engine = engine
        @config = {
          backup_dir: config[:backup_dir] || "backups",
          format: config[:format] || FORMAT_COMPRESSED,
          compression_level: config[:compression_level] || 6,
          encryption_key: config[:encryption_key],
          parallel_threads: config[:parallel_threads] || 4,
          chunk_size: config[:chunk_size] || 10 * 1024 * 1024, # 10MB
          retention_days: config[:retention_days] || 30,
          max_backups: config[:max_backups] || 10,
          verify_after_backup: config[:verify_after_backup] != false,
          include_wal: config[:include_wal] != false,
          include_schema: config[:include_schema] != false
        }

        @stats = {
          backups_created: 0,
          backups_restored: 0,
          total_size_bytes: 0,
          total_time_ms: 0,
          avg_time_ms: 0,
          last_backup: nil,
          last_backup_size: 0,
          errors: 0
        }
        @lock = Mutex.new
        @running = false

        # Create backup directory
        FileUtils.mkdir_p(@config[:backup_dir])
      end

      def create_backup(options = {})
        @lock.synchronize do
          start_time = Time.now
          @stats[:backups_created] += 1

          backup_type = options[:type] || TYPE_FULL
          backup_name = generate_backup_name(backup_type)
          backup_path = File.join(@config[:backup_dir], backup_name)

          begin
            # Create backup directory
            FileUtils.mkdir_p(backup_path)

            # Backup metadata
            metadata = {
              name: backup_name,
              type: backup_type,
              created_at: Time.now.iso8601,
              engine_version: RubyDB::VERSION,
              database_name: @engine.current_database_name,
              tables: list_tables,
              size: 0,
              checksum: nil,
              format: @config[:format],
              options: options
            }

            # Perform backup based on type
            case backup_type
            when TYPE_FULL
              backup_full(backup_path, metadata)
            when TYPE_INCREMENTAL
              backup_incremental(backup_path, metadata, options[:base_backup])
            when TYPE_DIFFERENTIAL
              backup_differential(backup_path, metadata, options[:base_backup])
            else
              backup_full(backup_path, metadata)
            end

            # Create manifest
            manifest_path = File.join(backup_path, "manifest.json")
            File.write(manifest_path, JSON.generate(metadata))

            # Verify backup
            if @config[:verify_after_backup]
              verification = verify_backup(backup_path)
              unless verification[:success]
                @stats[:errors] += 1
                return { success: false, error: "Verification failed", details: verification }
              end
            end

            # Update stats
            elapsed_ms = (Time.now - start_time) * 1000
            @stats[:total_time_ms] += elapsed_ms
            @stats[:avg_time_ms] = @stats[:total_time_ms] / @stats[:backups_created]
            @stats[:last_backup] = Time.now
            @stats[:last_backup_size] = metadata[:size]

            # Clean old backups
            clean_old_backups

            {
              success: true,
              backup_name: backup_name,
              backup_path: backup_path,
              size: metadata[:size],
              elapsed_ms: elapsed_ms,
              metadata: metadata
            }

          rescue => e
            @stats[:errors] += 1
            FileUtils.rm_rf(backup_path) if Dir.exist?(backup_path)
            { success: false, error: e.message }
          end
        end
      end

      def list_backups
        @lock.synchronize do
          backups = []
          Dir.glob(File.join(@config[:backup_dir], "backup_*")).each do |path|
            manifest_path = File.join(path, "manifest.json")
            next unless File.exist?(manifest_path)

            begin
              metadata = JSON.parse(File.read(manifest_path), symbolize_names: true)
              size = Dir.glob(File.join(path, "**/*")).sum { |f| File.size(f) if File.file?(f) } || 0
              backups << metadata.merge(
                path: path,
                size: size,
                size_human: format_size(size),
                age: Time.now - Time.parse(metadata[:created_at])
              )
            rescue
              # Skip corrupted manifests
            end
          end

          backups.sort_by { |b| b[:created_at] }.reverse
        end
      end

      def delete_backup(backup_name)
        @lock.synchronize do
          backup_path = File.join(@config[:backup_dir], backup_name)
          unless Dir.exist?(backup_path)
            return { success: false, error: "Backup not found" }
          end

          FileUtils.rm_rf(backup_path)
          { success: true }
        end
      end

      def verify_backup(backup_path)
        @lock.synchronize do
          manifest_path = File.join(backup_path, "manifest.json")
          unless File.exist?(manifest_path)
            return { success: false, error: "Manifest not found" }
          end

          begin
            metadata = JSON.parse(File.read(manifest_path), symbolize_names: true)

            # Verify all files exist
            expected_files = metadata[:files] || []
            missing_files = expected_files.reject { |f| File.exist?(File.join(backup_path, f)) }

            if missing_files.any?
              return { success: false, error: "Missing files", missing: missing_files }
            end

            # Verify checksums
            if metadata[:checksum]
              # In production, would verify checksum of all files
            end

            { success: true }
          rescue => e
            { success: false, error: e.message }
          end
        end
      end

      def clean_old_backups
        @lock.synchronize do
          backups = list_backups

          # Remove by retention days
          cutoff = Time.now - @config[:retention_days] * 24 * 60 * 60
          backups.select { |b| Time.parse(b[:created_at]) < cutoff }.each do |b|
            delete_backup(b[:name])
          end

          # Remove by count
          backups = list_backups
          if backups.size > @config[:max_backups]
            backups.last(backups.size - @config[:max_backups]).each do |b|
              delete_backup(b[:name])
            end
          end
        end
      end

      def stats
        @lock.synchronize do
          backups = list_backups
          total_size = backups.sum { |b| b[:size] || 0 }

          @stats.merge({
            backups_count: backups.size,
            total_size: total_size,
            total_size_human: format_size(total_size),
            config: @config,
            running: @running
          })
        end
      end

      private

      def generate_backup_name(type)
        timestamp = Time.now.strftime("%Y%m%d_%H%M%S")
        "backup_#{type}_#{timestamp}_#{rand(10000)}"
      end

      def list_tables
        @engine.list_tables rescue []
      end

      def backup_full(backup_path, metadata)
        files = []

        # Backup data files
        data_files = @engine.data_files rescue []
        data_files.each do |file|
          dest = File.join(backup_path, File.basename(file))
          copy_file(file, dest)
          files << File.basename(file)
        end

        # Backup WAL
        if @config[:include_wal]
          wal_files = @engine.wal_files rescue []
          wal_files.each do |file|
            dest = File.join(backup_path, "wal", File.basename(file))
            FileUtils.mkdir_p(File.dirname(dest))
            copy_file(file, dest)
            files << "wal/#{File.basename(file)}"
          end
        end

        # Backup schema
        if @config[:include_schema]
          schema_path = File.join(backup_path, "schema.sql")
          File.write(schema_path, @engine.schema_dump)
          files << "schema.sql"
        end

        metadata[:files] = files
        metadata[:size] = calculate_backup_size(backup_path)
        metadata[:checksum] = calculate_checksum(backup_path)
      end

      def backup_incremental(backup_path, metadata, base_backup)
        # In production, would backup changes since base backup
        metadata[:base_backup] = base_backup
        backup_full(backup_path, metadata)
      end

      def backup_differential(backup_path, metadata, base_backup)
        # In production, would backup changes since base backup
        metadata[:base_backup] = base_backup
        backup_full(backup_path, metadata)
      end

      def copy_file(src, dest)
        if @config[:format] == FORMAT_COMPRESSED
          compress_file(src, dest)
        else
          FileUtils.cp(src, dest)
        end
      end

      def compress_file(src, dest)
        Zlib::GzipWriter.open(dest) do |gz|
          File.open(src, "rb") do |file|
            while chunk = file.read(@config[:chunk_size])
              gz.write(chunk)
            end
          end
        end
      end

      def calculate_backup_size(backup_path)
        Dir.glob(File.join(backup_path, "**/*")).sum do |f|
          File.size(f) if File.file?(f)
        end || 0
      end

      def calculate_checksum(backup_path)
        # In production, would calculate checksum of all files
        nil
      end

      def format_size(bytes)
        return "0 B" if bytes == 0
        units = ["B", "KB", "MB", "GB", "TB"]
        exp = (Math.log(bytes) / Math.log(1024)).floor
        size = bytes / (1024.0 ** exp)
        "#{size.round(2)} #{units[exp]}"
      end
    end
  end
end