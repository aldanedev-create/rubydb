# frozen_string_literal: true

require "fileutils"
require "zlib"
require "time"

module RubyDB
  module WAL
    # Archive - Manages WAL archiving and restoration
    class Archive
      attr_reader :stats

      def initialize(wal_dir, archive_dir = nil, config = {})
        @wal_dir = wal_dir
        @archive_dir = archive_dir || File.join(wal_dir, "archive")
        @config = config
        @compression = config[:compression] || true
        @max_archive_size = config[:max_size] || 10 * 1024 * 1024 * 1024  # 10GB
        @retention_days = config[:retention_days] || 30
        @stats = {
          archives_created: 0,
          archives_restored: 0,
          archives_deleted: 0,
          total_archive_size: 0,
          compressed_bytes: 0,
          uncompressed_bytes: 0,
          archive_failures: 0
        }
        @lock = Mutex.new

        # Create archive directory
        FileUtils.mkdir_p(@archive_dir)
      end

      def archive_segment(segment)
        @lock.synchronize do
          start_time = Time.now

          begin
            # Check if segment exists
            unless segment.exists?
              return false
            end

            # Archive the segment
            archive_path = segment.archive
            archive_size = File.size(archive_path)

            # Compress if enabled
            if @compression && archive_size > 0
              compressed_path = "#{archive_path}.gz"
              compress_file(archive_path, compressed_path)
              File.delete(archive_path)
              archive_path = compressed_path
              archive_size = File.size(archive_path)
              @stats[:compressed_bytes] += archive_size
            end

            @stats[:archives_created] += 1
            @stats[:total_archive_size] += archive_size
            @stats[:uncompressed_bytes] += archive_size

            # Clean old archives if needed
            clean_old_archives

            { path: archive_path, size: archive_size }

          rescue => e
            @stats[:archive_failures] += 1
            raise
          end
        end
      end

      def restore_archive(segment_id)
        @lock.synchronize do
          # Find archive file
          archive_path = File.join(@archive_dir, "wal_#{segment_id.to_s.rjust(8, '0')}.log")

          unless File.exist?(archive_path)
            # Try compressed
            compressed_path = "#{archive_path}.gz"
            if File.exist?(compressed_path)
              archive_path = compressed_path
            else
              return false
            end
          end

          # Decompress if needed
          if archive_path.end_with?(".gz")
            decompressed_path = archive_path.gsub(/\.gz$/, "")
            decompress_file(archive_path, decompressed_path)
            archive_path = decompressed_path
          end

          # Copy to WAL directory
          wal_path = File.join(@wal_dir, "wal_#{segment_id.to_s.rjust(8, '0')}.log")
          FileUtils.cp(archive_path, wal_path)

          @stats[:archives_restored] += 1
          wal_path
        end
      end

      def list_archives
        @lock.synchronize do
          archives = []

          Dir.glob(File.join(@archive_dir, "wal_*.log*")).each do |path|
            if path =~ /wal_(\d+)\.log(?:\.gz)?$/
              segment_id = $1.to_i
              size = File.size(path)
              modified = File.mtime(path)

              archives << {
                segment_id: segment_id,
                path: path,
                size: size,
                modified: modified,
                compressed: path.end_with?(".gz")
              }
            end
          end

          archives.sort_by { |a| a[:segment_id] }
        end
      end

      def clean_old_archives
        @lock.synchronize do
          # Check total size
          archives = list_archives
          total_size = archives.sum { |a| a[:size] }

          # If over limit, remove oldest
          if total_size > @max_archive_size
            archives.sort_by! { |a| a[:modified] }
            archives.each do |archive|
              break if total_size <= @max_archive_size

              File.delete(archive[:path])
              total_size -= archive[:size]
              @stats[:archives_deleted] += 1
            end
          end

          # Remove old archives
          cutoff = Time.now - @retention_days * 24 * 60 * 60
          archives.each do |archive|
            if archive[:modified] < cutoff
              File.delete(archive[:path])
              @stats[:archives_deleted] += 1
            end
          end
        end
      end

      def stats
        @lock.synchronize do
          archives = list_archives
          total_size = archives.sum { |a| a[:size] }

          @stats.merge({
            archive_count: archives.size,
            total_archive_size: total_size,
            retention_days: @retention_days,
            max_archive_size: @max_archive_size,
            compression: @compression
          })
        end
      end

      private

      def compress_file(source, destination)
        File.open(source, "rb") do |input|
          Zlib::GzipWriter.open(destination) do |output|
            output.write(input.read)
          end
        end
      end

      def decompress_file(source, destination)
        Zlib::GzipReader.open(source) do |input|
          File.open(destination, "wb") do |output|
            output.write(input.read)
          end
        end
      end
    end
  end
end