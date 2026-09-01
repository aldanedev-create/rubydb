# frozen_string_literal: true

require "fileutils"

module RubyDB
  module WAL
    # Segment - A WAL segment file
    class Segment
      attr_reader :segment_id, :path, :size, :max_size
      attr_reader :first_lsn, :last_lsn, :record_count

      DEFAULT_MAX_SIZE = 16 * 1024 * 1024  # 16MB

      def initialize(segment_id, wal_dir, max_size = DEFAULT_MAX_SIZE)
        @segment_id = segment_id
        @wal_dir = wal_dir
        @max_size = max_size
        @path = File.join(wal_dir, "wal_#{segment_id.to_s.rjust(8, '0')}.log")
        @size = 0
        @record_count = 0
        @first_lsn = nil
        @last_lsn = nil
        @file = nil
        @is_open = false
        @is_full = false
        @lock = Mutex.new
      end

      def open
        @lock.synchronize do
          return if @is_open

          FileUtils.mkdir_p(@wal_dir) unless Dir.exist?(@wal_dir)

          if File.exist?(@path)
            @file = File.open(@path, "a+b")
            @size = File.size(@path)
            @record_count = count_records
          else
            @file = File.open(@path, "w+b")
            @size = 0
            @record_count = 0
          end

          @is_open = true
          self
        end
      end

      def close
        @lock.synchronize do
          return unless @is_open

          @file.close if @file
          @is_open = false
          true
        end
      end

      def append(record_data, lsn)
        @lock.synchronize do
          raise "Segment is full" if @is_full
          raise "Segment not open" unless @is_open

          # Write record
          @file.seek(0, IO::SEEK_END)
          @file.write(record_data)
          @file.flush

          @size += record_data.bytesize
          @record_count += 1

          @first_lsn ||= lsn
          @last_lsn = lsn

          # Check if segment is full
          if @size >= @max_size
            @is_full = true
            return :full
          end

          :ok
        end
      end

      def read_at(offset, length)
        @lock.synchronize do
          raise "Segment not open" unless @is_open

          @file.seek(offset)
          @file.read(length)
        end
      end

      def read_record_at(offset)
        @lock.synchronize do
          raise "Segment not open" unless @is_open

          # Read checksum (16 bytes) and record length marker
          header = @file.read(16)
          return nil if header.nil? || header.empty?

          # Read the rest of the record
          # In production, record length would be stored in header
          # For simplicity, we read until EOF or next record marker
          # This is simplified - production would have proper length prefix

          # For now, read the entire remaining data (not efficient for production)
          @file.seek(offset)
          @file.read
        end
      end

      def truncate
        @lock.synchronize do
          return unless @is_open

          @file.truncate(0)
          @size = 0
          @record_count = 0
          @first_lsn = nil
          @last_lsn = nil
          @is_full = false
          true
        end
      end

      def full?
        @is_full
      end

      def open?
        @is_open
      end

      def exists?
        File.exist?(@path)
      end

      def delete
        @lock.synchronize do
          close if @is_open
          File.delete(@path) if exists?
          true
        end
      end

      def archive
        # Move segment to archive
        archived_path = File.join(@wal_dir, "archive", "wal_#{@segment_id.to_s.rjust(8, '0')}.log")
        FileUtils.mkdir_p(File.dirname(archived_path))
        FileUtils.mv(@path, archived_path)
        archived_path
      end

      def to_s
        "Segment(#{@segment_id}, size=#{@size}, records=#{@record_count}, full=#{@is_full})"
      end

      def inspect
        to_s
      end

      private

      def count_records
        # In production, this would parse the segment to count records
        # For now, return 0
        0
      end
    end
  end
end