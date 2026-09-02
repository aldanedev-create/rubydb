# frozen_string_literal: true

require "fileutils"
require "time"
require "json"
require "zlib"
require "openssl"
require "digest"
require "monitor"
require "open3"
require "pathname"

module RubyDB
  module Backup
    # Archive - Archives backups for long-term storage
    class Archive
      attr_reader :stats

      def initialize(config = {})
        @config = config
        @archive_dir = config[:archive_dir] || "archive"
        @storage_backend = config[:storage_backend] || :local  # :local, :s3, :gcs, :azure
        @compression = config[:compression] != false
        @encryption = config[:encryption] || false
        @encryption_key = config[:encryption_key]
        @retention_days = config[:retention_days] || 365
        @max_archives = config[:max_archives] || 100
        @stats = {
          archives_created: 0,
          archives_restored: 0,
          archives_deleted: 0,
          total_size_bytes: 0,
          last_archive: nil,
          errors: 0
        }
        @lock = Monitor.new

        FileUtils.mkdir_p(@archive_dir)
      end

      def archive_backup(backup_path, options = {})
        @lock.synchronize do
          start_time = Time.now

          unless Dir.exist?(backup_path)
            return { success: false, error: "Backup path does not exist" }
          end

          backup_name = File.basename(backup_path)
          archive_name = "archive_#{backup_name}_#{Time.now.strftime('%Y%m%d_%H%M%S')}.tar"
          archive_path = File.join(@archive_dir, archive_name)

          begin
            # Create tar archive
            create_tar_archive(backup_path, archive_path)

            # Compress if enabled
            if @compression
              compress_file(archive_path)
              archive_path += ".gz"
            end

            # Encrypt if enabled
            if @encryption && @encryption_key
              encrypt_file(archive_path)
              archive_path += ".enc"
            end

            # Calculate checksum
            checksum = calculate_checksum(archive_path)

            # Create metadata
            metadata = {
              name: File.basename(archive_path),
              original_backup: backup_name,
              created_at: Time.now.iso8601,
              size: File.size(archive_path),
              checksum: checksum,
              compression: @compression,
              encryption: @encryption,
              storage_backend: @storage_backend
            }

            # Write metadata
            metadata_path = "#{archive_path}.meta"
            File.write(metadata_path, JSON.generate(metadata))

            # Update stats
            @stats[:archives_created] += 1
            @stats[:total_size_bytes] += metadata[:size]
            @stats[:last_archive] = Time.now

            # Clean old archives
            clean_old_archives

            {
              success: true,
              archive_path: archive_path,
              metadata: metadata,
              elapsed_ms: (Time.now - start_time) * 1000
            }

          rescue => e
            @stats[:errors] += 1
            File.delete(archive_path) if File.exist?(archive_path)
            { success: false, error: e.message }
          end
        end
      end

      def restore_archive(archive_path, destination = nil)
        @lock.synchronize do
          start_time = Time.now
          temporary_paths = []

          unless File.exist?(archive_path)
            return { success: false, error: "Archive file does not exist" }
          end

          # Determine destination
          destination ||= File.join(@archive_dir, "restored_#{Time.now.strftime('%Y%m%d_%H%M%S')}")
          FileUtils.mkdir_p(destination)

          begin
            # Decrypt if encrypted
            if archive_path.end_with?(".enc")
              decrypted_path = archive_path.gsub(/\.enc$/, "")
              decrypt_file(archive_path, decrypted_path)
              temporary_paths << decrypted_path
              archive_path = decrypted_path
            end

            # Decompress if compressed
            if archive_path.end_with?(".gz")
              decompressed_path = archive_path.gsub(/\.gz$/, "")
              decompress_file(archive_path, decompressed_path)
              temporary_paths << decompressed_path
              archive_path = decompressed_path
            end

            # Extract tar archive
            extract_tar_archive(archive_path, destination)

            @stats[:archives_restored] += 1

            {
              success: true,
              destination: destination,
              elapsed_ms: (Time.now - start_time) * 1000
            }

          rescue => e
            @stats[:errors] += 1
            { success: false, error: e.message }
          ensure
            temporary_paths.each { |path| File.delete(path) if File.file?(path) }
          end
        end
      end

      def list_archives
        @lock.synchronize do
          archives = []
          Dir.glob(File.join(@archive_dir, "archive_*")).each do |path|
            metadata_path = "#{path}.meta"
            next unless File.exist?(metadata_path)

            begin
              metadata = JSON.parse(File.read(metadata_path), symbolize_names: true)
              archives << metadata.merge(path: path)
            rescue
              # Skip corrupted metadata
            end
          end

          archives.sort_by { |a| a[:created_at] }.reverse
        end
      end

      def delete_archive(archive_name)
        @lock.synchronize do
          archive_path = archive_path_for_name(archive_name)
          return { success: false, error: "Invalid archive name" } unless archive_path

          unless File.exist?(archive_path)
            return { success: false, error: "Archive not found" }
          end

          File.delete(archive_path)
          metadata_path = "#{archive_path}.meta"
          File.delete(metadata_path) if File.exist?(metadata_path)

          @stats[:archives_deleted] += 1

          { success: true }
        end
      end

      def stats
        @lock.synchronize do
          archives = list_archives
          total_size = archives.sum { |a| a[:size] || 0 }

          @stats.merge({
            archives: archives.size,
            total_size: total_size,
            total_size_human: format_size(total_size),
            archive_dir: @archive_dir,
            storage_backend: @storage_backend
          })
        end
      end

      private

      def archive_path_for_name(archive_name)
        name = archive_name.to_s
        return nil if name.empty? || name != File.basename(name)

        root = File.expand_path(@archive_dir)
        path = File.expand_path(File.join(root, name))
        path.start_with?("#{root}#{File::SEPARATOR}") ? path : nil
      end

      def create_tar_archive(source, destination)
        require "archive/tar/minitar"
        Archive::Tar::Minitar.pack(source, File.open(destination, "wb"))
      rescue LoadError
        # Fallback to system tar command
        raise "tar utility is unavailable" unless system("tar", "-cf", destination, "-C", File.dirname(source), File.basename(source))
      end

      def extract_tar_archive(source, destination)
        require "archive/tar/minitar"
        Archive::Tar::Minitar.unpack(source, destination)
      rescue LoadError
        # Fallback to system tar command
        validate_tar_entries!(source, destination)
        raise "tar utility is unavailable" unless system("tar", "-xf", source, "-C", destination)
      end

      def validate_tar_entries!(source, destination)
        output, error, status = Open3.capture3("tar", "-tf", source)
        raise "Unable to inspect tar archive: #{error}" unless status.success?

        root = File.expand_path(destination)
        invalid_entries = output.lines.map(&:strip).reject do |entry|
          !entry.empty? && !Pathname.new(entry).absolute? && begin
            path = File.expand_path(File.join(root, entry))
            path.start_with?("#{root}#{File::SEPARATOR}")
          end
        end
        raise "Archive contains unsafe paths: #{invalid_entries.join(', ')}" if invalid_entries.any?
      end

      def compress_file(file_path)
        Zlib::GzipWriter.open("#{file_path}.gz") do |gz|
          File.open(file_path, "rb") do |file|
            while chunk = file.read(10 * 1024 * 1024)
              gz.write(chunk)
            end
          end
        end
        File.delete(file_path)
      end

      def decompress_file(file_path, destination)
        Zlib::GzipReader.open(file_path) do |gz|
          File.open(destination, "wb") do |file|
            while chunk = gz.read(10 * 1024 * 1024)
              file.write(chunk)
            end
          end
        end
      end

      def encrypt_file(file_path)
        key = Digest::SHA256.digest(@encryption_key.to_s)
        nonce = OpenSSL::Random.random_bytes(12)
        cipher = OpenSSL::Cipher.new("aes-256-gcm")
        cipher.encrypt
        cipher.key = key
        cipher.iv = nonce
        ciphertext = cipher.update(File.binread(file_path)) + cipher.final
        File.binwrite("#{file_path}.enc", nonce + cipher.auth_tag + ciphertext)
        File.delete(file_path)
      end

      def decrypt_file(file_path, destination)
        payload = File.binread(file_path)
        raise "Encrypted archive is truncated" if payload.bytesize < 28

        key = Digest::SHA256.digest(@encryption_key.to_s)
        cipher = OpenSSL::Cipher.new("aes-256-gcm")
        cipher.decrypt
        cipher.key = key
        cipher.iv = payload.byteslice(0, 12)
        cipher.auth_tag = payload.byteslice(12, 16)
        plaintext = cipher.update(payload.byteslice(28..-1)) + cipher.final
        File.binwrite(destination, plaintext)
      end

      def calculate_checksum(file_path)
        Digest::SHA256.file(file_path).hexdigest
      end

      def clean_old_archives
        archives = list_archives

        # Remove by retention days
        cutoff = Time.now - @retention_days * 24 * 60 * 60
        archives.select { |a| Time.parse(a[:created_at]) < cutoff }.each do |a|
          delete_archive(File.basename(a[:path]))
        end

        # Remove by count
        archives = list_archives
        if archives.size > @max_archives
          archives.last(archives.size - @max_archives).each do |a|
            delete_archive(File.basename(a[:path]))
          end
        end
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
