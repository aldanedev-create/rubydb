# frozen_string_literal: true

require "fileutils"
require "time"
require "json"
require "zlib"
require "digest"
require "monitor"
require "pathname"

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
        @lock = Monitor.new
        @running = false

        # Create backup directory
        FileUtils.mkdir_p(@config[:backup_dir])
      end

      def create_backup(options = {})
        @lock.synchronize do
          start_time = Time.now
          @stats[:backups_created] += 1

          backup_type = options[:type] || TYPE_FULL
          if backup_type == TYPE_INCREMENTAL
            begin
              return Incremental.new(@engine, @config.merge(
                incremental_dir: @config[:incremental_dir] || File.join(@config[:backup_dir], "incremental")
              )).create_incremental(options[:base_backup])
            rescue StandardError => error
              @stats[:errors] += 1
              return { success: false, error: error.message }
            end
          elsif backup_type == TYPE_DIFFERENTIAL
            begin
              return Incremental.new(@engine, @config.merge(
                incremental_dir: @config[:incremental_dir] || File.join(@config[:backup_dir], "incremental")
              )).create_differential(options[:base_backup])
            rescue StandardError => error
              @stats[:errors] += 1
              return { success: false, error: error.message }
            end
          end
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
            if @engine.respond_to?(:wal) && @engine.wal.respond_to?(:current_lsn)
              metadata[:lsn] = @engine.wal.current_lsn.to_i
            end

            # Perform backup based on type
            case backup_type
            when TYPE_FULL
              backup_full(backup_path, metadata)
            when TYPE_INCREMENTAL, TYPE_DIFFERENTIAL
              raise ArgumentError, "Backup type dispatch error"
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
              size = Dir.glob(File.join(path, "**/*")).select { |f| File.file?(f) }.sum { |f| File.size(f) }
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
          backup_path = backup_path_for_name(backup_name)
          return { success: false, error: "Invalid backup name" } unless backup_path

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
            invalid_files = expected_files.reject { |file| manifest_file_path(backup_path, file) }
            return { success: false, error: "Invalid manifest file path", invalid: invalid_files } if invalid_files.any?

            missing_files = expected_files.reject { |file| File.exist?(manifest_file_path(backup_path, file)) }

            if missing_files.any?
              return { success: false, error: "Missing files", missing: missing_files }
            end

            # Verify checksums
            if metadata[:checksum]
              actual_checksum = calculate_checksum(backup_path)
              return { success: false, error: "Checksum mismatch", expected: metadata[:checksum], actual: actual_checksum } unless actual_checksum == metadata[:checksum]
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

      def backup_path_for_name(backup_name)
        name = backup_name.to_s
        return nil if name.empty? || name != File.basename(name)

        root = File.expand_path(@config[:backup_dir])
        path = File.expand_path(File.join(root, name))
        path == root || path.start_with?("#{root}#{File::SEPARATOR}") ? path : nil
      end

      def manifest_file_path(root_path, relative_path)
        relative = relative_path.to_s
        return nil if relative.empty? || Pathname.new(relative).absolute?

        root = File.expand_path(root_path)
        path = File.expand_path(File.join(root, relative))
        path.start_with?("#{root}#{File::SEPARATOR}") ? path : nil
      end

      def generate_backup_name(type)
        timestamp = Time.now.strftime("%Y%m%d_%H%M%S")
        "backup_#{type}_#{timestamp}_#{rand(10000)}"
      end

      def list_tables
        return [] unless @engine.respond_to?(:list_tables)

        @engine.list_tables
      end

      def backup_full(backup_path, metadata)
        files = []

        # Backup data files
        data_files = @engine.respond_to?(:data_files) ? @engine.data_files : []
        data_files.each do |file|
          name = File.basename(file)
          name = "#{name}.gz" if @config[:format] == FORMAT_COMPRESSED
          dest = File.join(backup_path, name)
          copy_file(file, dest)
          files << name
        end

        # Backup WAL
        if @config[:include_wal]
          wal_files = @engine.respond_to?(:wal_files) ? @engine.wal_files : []
          wal_files.each do |file|
            name = File.basename(file)
            name = "#{name}.gz" if @config[:format] == FORMAT_COMPRESSED
            dest = File.join(backup_path, "wal", name)
            FileUtils.mkdir_p(File.dirname(dest))
            copy_file(file, dest)
            files << "wal/#{name}"
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
        Dir.glob(File.join(backup_path, "**/*")).select { |f| File.file?(f) }.sum { |f| File.size(f) }
      end

      def calculate_checksum(backup_path)
        digest = Digest::SHA256.new
        Dir.glob(File.join(backup_path, "**/*")).select { |path| File.file?(path) }.sort.each do |path|
          relative = path.delete_prefix("#{backup_path}#{File::SEPARATOR}")
          next if relative == "manifest.json"
          digest.update(relative)
          digest.update(File.binread(path))
        end
        digest.hexdigest
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
