# frozen_string_literal: true

module RubyDB
  module WAL
    # Reader - Reads records from the WAL
    class Reader
      attr_reader :stats

      def initialize(wal_dir, config = {})
        @wal_dir = wal_dir
        @config = config
        @segments = []
        @current_segment_index = 0
        @stats = {
          records_read: 0,
          bytes_read: 0,
          segments_read: 0,
          segment_skips: 0,
          corrupted_records: 0
        }
        @lock = Mutex.new
        @batch_size = config[:batch_size] || 1000

        load_segments
      end

      def read_all
        @lock.synchronize do
          records = []
          @segments.each do |segment|
            records.concat(_read_segment(segment))
          end
          records
        end
      end

      def read_from_lsn(start_lsn)
        @lock.synchronize do
          records = []
          found_start = false

          @segments.each do |segment|
            if segment.segment_id < start_lsn.segment_id
              next
            end

            if segment.segment_id == start_lsn.segment_id
              # Read from offset
              records.concat(_read_segment_from_offset(segment, start_lsn.offset))
            else
              records.concat(_read_segment(segment))
            end

            break if @config[:limit] && records.size >= @config[:limit]
          end

          records
        end
      end

      def read_to_lsn(end_lsn)
        @lock.synchronize do
          records = []

          @segments.each do |segment|
            break if segment.segment_id > end_lsn.segment_id

            if segment.segment_id == end_lsn.segment_id
              records.concat(_read_segment_to_offset(segment, end_lsn.offset))
            else
              records.concat(_read_segment(segment))
            end
          end

          records
        end
      end

      def read_range(start_lsn, end_lsn)
        @lock.synchronize do
          records = []

          @segments.each do |segment|
            break if segment.segment_id > end_lsn.segment_id
            next if segment.segment_id < start_lsn.segment_id

            if segment.segment_id == start_lsn.segment_id
              records.concat(_read_segment_range(segment, start_lsn.offset, end_lsn.offset))
            elsif segment.segment_id == end_lsn.segment_id
              records.concat(_read_segment_to_offset(segment, end_lsn.offset))
            else
              records.concat(_read_segment(segment))
            end
          end

          records
        end
      end

      def read_segment(segment)
        @lock.synchronize do
          _read_segment(segment)
        end
      end

      private def _read_segment(segment)
        records = []
        offset = 0

        puts "WAL DEBUG: _read_segment starting for segment #{segment.segment_id}" if ENV['DEBUG_RECOVERY']
        while true
          record_data = segment.read_record_at(offset)
          break if record_data.nil? || record_data.empty?
          puts "WAL DEBUG: read record at offset #{offset}, size=#{record_data.bytesize}" if ENV['DEBUG_RECOVERY']

          begin
            lsn = LSN.new(segment.segment_id, offset)
            record = Record.deserialize(record_data, lsn)
            records << record
            @stats[:records_read] += 1
            @stats[:bytes_read] += record_data.bytesize
            offset += record_data.bytesize
            puts "WAL DEBUG: deserialized record #{record.type}" if ENV['DEBUG_RECOVERY']
          rescue => e
            @stats[:corrupted_records] += 1
            puts "WAL DEBUG: failed to deserialize at offset #{offset}: #{e.message}" if ENV['DEBUG_RECOVERY']
            break
          end
        end

        @stats[:segments_read] += 1
        puts "WAL DEBUG: finished reading segment #{segment.segment_id}, found #{records.count} records" if ENV['DEBUG_RECOVERY']
        records
      end

      private def _read_segment_from_offset(segment, offset)
        records = []
        current_offset = offset

        while true
          record_data = segment.read_record_at(current_offset)
          break if record_data.nil? || record_data.empty?

          begin
            lsn = LSN.new(segment.segment_id, current_offset)
            record = Record.deserialize(record_data, lsn)
            records << record
            @stats[:records_read] += 1
            @stats[:bytes_read] += record_data.bytesize
            current_offset += record_data.bytesize
          rescue => e
            @stats[:corrupted_records] += 1
            break
          end
        end

        records
      end

      private def _read_segment_to_offset(segment, offset)
        records = []
        current_offset = 0

        while current_offset < offset
          record_data = segment.read_record_at(current_offset)
          break if record_data.nil? || record_data.empty?

          begin
            lsn = LSN.new(segment.segment_id, current_offset)
            record = Record.deserialize(record_data, lsn)
            records << record
            @stats[:records_read] += 1
            @stats[:bytes_read] += record_data.bytesize
            current_offset += record_data.bytesize
          rescue => e
            @stats[:corrupted_records] += 1
            break
          end
        end

        records
      end

      private def _read_segment_range(segment, start_offset, end_offset)
        records = []
        current_offset = start_offset

        while current_offset < end_offset
          record_data = segment.read_record_at(current_offset)
          break if record_data.nil? || record_data.empty?

          begin
            lsn = LSN.new(segment.segment_id, current_offset)
            record = Record.deserialize(record_data, lsn)
            records << record
            @stats[:records_read] += 1
            @stats[:bytes_read] += record_data.bytesize
            current_offset += record_data.bytesize
          rescue => e
            @stats[:corrupted_records] += 1
            break
          end
        end

        records
      end

      def reload
        @lock.synchronize do
          @segments.clear
          @current_segment_index = 0
          load_segments
          true
        end
      end

      def stats
        @lock.synchronize do
          @stats.merge({
            segments_loaded: @segments.size,
            current_segment: @current_segment_index,
            batch_size: @batch_size
          })
        end
      end

      private

      def load_segments
        @segments = []

        # Find all WAL segment files
        wal_files = Dir.glob(File.join(@wal_dir, "wal_*.log"))
        puts "WAL DEBUG: found #{wal_files.count} WAL files: #{wal_files.map { |f| File.basename(f) }.inspect}" if ENV['DEBUG_RECOVERY']
        wal_files.sort.each do |file_path|
          # Extract segment ID from filename
          if file_path =~ /wal_(\d+)\.log$/
            segment_id = $1.to_i
            segment = Segment.new(segment_id, @wal_dir)
            if segment.exists?
              segment.open
              @segments << segment
              puts "WAL DEBUG: loaded segment #{segment_id}" if ENV['DEBUG_RECOVERY']
            end
          end
        end
        puts "WAL DEBUG: total segments loaded: #{@segments.count}" if ENV['DEBUG_RECOVERY']
      end
    end
  end
end