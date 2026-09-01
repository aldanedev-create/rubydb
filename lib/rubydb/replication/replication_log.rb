# frozen_string_literal: true

require "json"
require "fileutils"
require "time"

module RubyDB
  module Replication
    # ReplicationLog - Logs replication transactions
    class ReplicationLog
      attr_reader :stats

      def initialize(engine, config = {})
        @engine = engine
        @config = config
        @log_dir = config[:log_dir] || "replication_log"
        @max_segment_size = config[:max_segment_size] || 16 * 1024 * 1024
        @keep_segments = config[:keep_segments] || 100
        @current_segment = nil
        @current_segment_size = 0
        @segment_counter = 0
        @stats = {
          transactions_logged: 0,
          bytes_logged: 0,
          segments_created: 0,
          segments_archived: 0,
          segments_deleted: 0
        }
        @lock = Mutex.new

        create_log_directory
        open_current_segment
      end

      def log_transaction(transaction_data, lsn)
        @lock.synchronize do
          entry = {
            lsn: lsn,
            timestamp: Time.now.iso8601,
            transaction_id: transaction_data[:id],
            data: transaction_data
          }

          json = JSON.generate(entry) + "\n"
          @current_segment.write(json)
          @current_segment.flush

          @stats[:transactions_logged] += 1
          @stats[:bytes_logged] += json.bytesize
          @current_segment_size += json.bytesize

          # Rotate if segment is full
          if @current_segment_size >= @max_segment_size
            rotate_segment
          end

          true
        end
      end

      def read_transactions(from_lsn = nil, to_lsn = nil)
        @lock.synchronize do
          transactions = []
          segments = list_segments

          segments.each do |segment_path|
            File.open(segment_path, "r") do |file|
              file.each_line do |line|
                begin
                  entry = JSON.parse(line, symbolize_names: true)

                  # Filter by LSN range
                  if from_lsn && entry[:lsn] < from_lsn
                    next
                  end
                  if to_lsn && entry[:lsn] > to_lsn
                    next
                  end

                  transactions << entry
                rescue JSON::ParserError
                  # Skip malformed entries
                end
              end
            end
          end

          transactions
        end
      end

      def get_last_lsn
        @lock.synchronize do
          # Read the last entry from the current segment
          return nil unless @current_segment

          @current_segment.seek(0, IO::SEEK_END)

          # Read backwards to find last complete line
          pos = @current_segment.pos
          while pos > 0
            @current_segment.seek(pos - 1, IO::SEEK_SET)
            char = @current_segment.read(1)
            if char == "\n"
              line = @current_segment.readline
              begin
                entry = JSON.parse(line, symbolize_names: true)
                return entry[:lsn]
              rescue JSON::ParserError
                # Continue searching
              end
            end
            pos -= 1
          end

          nil
        end
      end

      def archive_segment(segment_name)
        @lock.synchronize do
          archive_dir = File.join(@log_dir, "archive")
          FileUtils.mkdir_p(archive_dir)

          src = File.join(@log_dir, segment_name)
          dst = File.join(archive_dir, segment_name)

          if File.exist?(src)
            FileUtils.mv(src, dst)
            @stats[:segments_archived] += 1
            return true
          end

          false
        end
      end

      def delete_old_segments
        @lock.synchronize do
          segments = list_segments
          return if segments.size <= @keep_segments

          to_delete = segments.first(segments.size - @keep_segments)
          to_delete.each do |segment_path|
            File.delete(segment_path)
            @stats[:segments_deleted] += 1
          end
        end
      end

      def stats
        @lock.synchronize do
          stats_hash = @stats.dup
          stats_hash[:current_segment] = File.basename(@current_segment.path) if @current_segment
          stats_hash[:current_segment_size] = @current_segment_size
          stats_hash[:segments_count] = list_segments.size
          stats_hash[:log_dir] = @log_dir
          stats_hash
        end
      end

      private

      def create_log_directory
        FileUtils.mkdir_p(@log_dir)
        FileUtils.mkdir_p(File.join(@log_dir, "archive"))
      end

      def open_current_segment
        @segment_counter += 1
        segment_name = "replication_#{Time.now.strftime('%Y%m%d_%H%M%S')}_#{@segment_counter}.log"
        segment_path = File.join(@log_dir, segment_name)

        @current_segment = File.open(segment_path, "a")
        @current_segment.sync = false
        @current_segment_size = File.size(segment_path)
        @stats[:segments_created] += 1
      end

      def rotate_segment
        @current_segment.close
        delete_old_segments
        open_current_segment
      end

      def list_segments
        Dir.glob(File.join(@log_dir, "replication_*.log")).sort
      end
    end
  end
end