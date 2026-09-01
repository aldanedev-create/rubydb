# frozen_string_literal: true

require "fileutils"

module RubyDB
  module WAL
    # Writer - Writes records to the WAL
    class Writer
      attr_reader :current_segment, :current_lsn, :stats

      def initialize(wal_dir, config = {})
        @wal_dir = wal_dir
        @config = config
        @segment_max_size = config[:segment_size] || Segment::DEFAULT_MAX_SIZE
        @current_segment = nil
        @current_lsn = LSN.new(1, 0)
        @buffer = []
        @buffer_size = config[:buffer_size] || 1024 * 1024  # 1MB
        @buffer_current_size = 0
        @sync_on_write = config[:sync] || true
        @stats = {
          records_written: 0,
          bytes_written: 0,
          segments_created: 0,
          segments_rotated: 0,
          buffer_flushes: 0,
          syncs: 0
        }
        @lock = Mutex.new
        @write_thread = nil
        @running = false
        @shutdown = false

        # Create WAL directory
        FileUtils.mkdir_p(@wal_dir)

        # Create first segment
        create_new_segment

        # Start background writer if async
        if config[:async] != false
          start_background_writer
        end
      end

      def write_record(record)
        @lock.synchronize do
          # Assign LSN
          lsn = next_lsn
          record.instance_variable_set(:@lsn, lsn)

          # Serialize record
          serialized = record.serialize
          record_data = serialized[:checksum] + serialized[:data]

          # Add to buffer
          @buffer << { record: record, data: record_data, lsn: lsn }
          @buffer_current_size += record_data.bytesize

          @stats[:records_written] += 1

          # Flush if buffer is full OR if sync is enabled (for durability)
          if @buffer_current_size >= @buffer_size || @sync_on_write
            flush_buffer
            _sync if @sync_on_write
          end

          lsn
        end
      end

      def write_batch(records)
        @lock.synchronize do
          start_lsn = nil
          last_lsn = nil

          records.each do |record|
            lsn = write_record(record)
            start_lsn ||= lsn
            last_lsn = lsn
          end

          flush_buffer if @buffer.any?

          { start_lsn: start_lsn, end_lsn: last_lsn, count: records.size }
        end
      end

      def flush
        @lock.synchronize do
          flush_buffer
          _sync if @sync_on_write
        end
      end

      def sync
        @lock.synchronize do
          _sync
        end
      end

      private def _sync
        if @current_segment && @current_segment.open?
          @current_segment.instance_variable_get(:@file).fsync
          @stats[:syncs] += 1
        end
      end

      def shutdown(wait = true)
        @lock.synchronize do
          @shutdown = true
          @running = false
          @write_thread&.kill if !wait
          flush
        end
      end

      def stats
        @lock.synchronize do
          @stats.merge({
            buffer_size: @buffer.size,
            buffer_bytes: @buffer_current_size,
            current_segment: @current_segment&.segment_id,
            current_lsn: @current_lsn.to_s,
            async: @running
          })
        end
      end

      private

      def create_new_segment
        segment_id = @current_segment ? @current_segment.segment_id + 1 : 1
        segment = Segment.new(segment_id, @wal_dir, @segment_max_size)
        segment.open
        @current_segment = segment
        @stats[:segments_created] += 1
        segment
      end

      def next_lsn
        @current_lsn = LSN.new(
          @current_segment.segment_id,
          @current_lsn.offset + 1
        )
      end

      def flush_buffer
        return if @buffer.empty?

        @stats[:buffer_flushes] += 1

        @buffer.each do |entry|
          # Check if current segment is full
          if @current_segment && @current_segment.full?
            rotate_segment
          end

          # Write to segment
          result = @current_segment.append(entry[:data], entry[:lsn])
          @stats[:bytes_written] += entry[:data].bytesize

          if result == :full
            rotate_segment
            # Re-write to new segment
            @current_segment.append(entry[:data], entry[:lsn])
          end
        end

        @buffer.clear
        @buffer_current_size = 0
      end

      def rotate_segment
        @current_segment.close
        @stats[:segments_rotated] += 1
        create_new_segment
      end

      def start_background_writer
        @running = true
        @write_thread = Thread.new do
          while !@shutdown
            sleep(1)
            begin
              if @buffer.any?
                flush
              end
            rescue => e
              # Log error but continue
            end
          end
        end
      end
    end
  end
end