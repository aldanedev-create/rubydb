# frozen_string_literal: true

require "fileutils"
require "time"

# Import all WAL components
require_relative "lsn"
require_relative "record"
require_relative "segment"
require_relative "writer"
require_relative "reader"
require_relative "checkpoint"
require_relative "archive"
require_relative "../errors/recovery_error"

module RubyDB
  module WAL
    # WAL - Main Write-Ahead Log interface
    class WAL
      attr_reader :writer, :reader, :checkpoint, :archive, :stats
      attr_reader :wal_dir, :current_lsn

      def initialize(wal_dir, config = {})
        @wal_dir = wal_dir
        @config = config
        @engine = config[:engine]
        @stats = {
          writes: 0,
          reads: 0,
          checkpoints: 0,
          archives: 0,
          restores: 0,
          errors: 0,
          total_write_time_ms: 0,
          total_read_time_ms: 0,
          avg_write_time_ms: 0,
          avg_read_time_ms: 0
        }
        @lock = Mutex.new
        @running = false
        @shutdown = false
        @current_lsn = LSN.null

        # Create WAL directory
        FileUtils.mkdir_p(wal_dir) unless Dir.exist?(wal_dir)

        # Initialize components
        initialize_components(config)

        # Start checkpoint if configured
        if config[:auto_checkpoint] != false
          @checkpoint.start
        end

        # Start recovery if needed
        if config[:recovery] != false
          recover
        end

        @running = true
      end

      def attach_engine(engine)
        @lock.synchronize { @engine = engine }
        self
      end

      def write(record)
        @lock.synchronize do
          start_time = Time.now
          @stats[:writes] += 1

          begin
            lsn = @writer.write_record(record)
            @current_lsn = lsn

            elapsed_ms = (Time.now - start_time) * 1000
            @stats[:total_write_time_ms] += elapsed_ms
            @stats[:avg_write_time_ms] = @stats[:total_write_time_ms] / @stats[:writes]

            lsn
          rescue => e
            @stats[:errors] += 1
            raise
          end
        end
      end

      def write_batch(records)
        @lock.synchronize do
          start_time = Time.now
          @stats[:writes] += records.size

          begin
            result = @writer.write_batch(records)
            @current_lsn = result[:end_lsn] if result[:end_lsn]

            elapsed_ms = (Time.now - start_time) * 1000
            @stats[:total_write_time_ms] += elapsed_ms
            @stats[:avg_write_time_ms] = @stats[:total_write_time_ms] / @stats[:writes]

            result
          rescue => e
            @stats[:errors] += 1
            raise
          end
        end
      end

      def read_all
        @lock.synchronize do
          start_time = Time.now
          @stats[:reads] += 1

          begin
            records = @reader.read_all

            elapsed_ms = (Time.now - start_time) * 1000
            @stats[:total_read_time_ms] += elapsed_ms
            @stats[:avg_read_time_ms] = @stats[:total_read_time_ms] / @stats[:reads]

            records
          rescue => e
            @stats[:errors] += 1
            raise
          end
        end
      end

      def read_from(lsn)
        @lock.synchronize do
          start_time = Time.now
          @stats[:reads] += 1

          begin
            records = @reader.read_from_lsn(lsn)

            elapsed_ms = (Time.now - start_time) * 1000
            @stats[:total_read_time_ms] += elapsed_ms
            @stats[:avg_read_time_ms] = @stats[:total_read_time_ms] / @stats[:reads]

            records
          rescue => e
            @stats[:errors] += 1
            raise
          end
        end
      end

      def read_range(start_lsn, end_lsn)
        @lock.synchronize do
          start_time = Time.now
          @stats[:reads] += 1

          begin
            records = @reader.read_range(start_lsn, end_lsn)

            elapsed_ms = (Time.now - start_time) * 1000
            @stats[:total_read_time_ms] += elapsed_ms
            @stats[:avg_read_time_ms] = @stats[:total_read_time_ms] / @stats[:reads]

            records
          rescue => e
            @stats[:errors] += 1
            raise
          end
        end
      end

      def create_checkpoint(force = false)
        @lock.synchronize do
          start_time = Time.now
          @stats[:checkpoints] += 1

          begin
            result = @checkpoint.create_checkpoint(force)
            @stats[:checkpoints] += 1 if result
            result
          rescue => e
            @stats[:errors] += 1
            raise
          end
        end
      end

      def archive_segment(segment_id)
        @lock.synchronize do
          @stats[:archives] += 1

          begin
            segment = Segment.new(segment_id, @wal_dir)
            if segment.exists?
              segment.open
              result = @archive.archive_segment(segment)
              segment.close
              result
            else
              false
            end
          rescue => e
            @stats[:errors] += 1
            raise
          end
        end
      end

      def archive_all_segments
        @lock.synchronize do
          archived = 0

          Dir.glob(File.join(@wal_dir, "wal_*.log")).each do |file_path|
            if file_path =~ /wal_(\d+)\.log$/
              segment_id = $1.to_i
              if archive_segment(segment_id)
                archived += 1
              end
            end
          end

          archived
        end
      end

      def restore_from_archive(segment_id)
        @lock.synchronize do
          @stats[:restores] += 1

          begin
            result = @archive.restore_archive(segment_id)
            # Reload reader after restore
            @reader.reload if result
            result
          rescue => e
            @stats[:errors] += 1
            raise
          end
        end
      end

      def restore_latest_archive
        @lock.synchronize do
          archives = @archive.list_archives
          return false if archives.empty?

          latest = archives.max_by { |a| a[:segment_id] }
          restore_from_archive(latest[:segment_id])
        end
      end

      def recover
        @lock.synchronize do
          # Find the latest checkpoint
          checkpoint_lsn = @checkpoint.restore_checkpoint(@reader)

          if checkpoint_lsn
            # Read records after checkpoint
            records = @reader.read_from_lsn(checkpoint_lsn)

            # Replay committed transactions
            committed_transactions = Set.new
            records.each do |record|
              case record.type
              when :commit
                committed_transactions.add(record.transaction_id)
              when :prepare
                # Handle prepared transactions
                if can_commit_prepared?(record)
                  committed_transactions.add(record.transaction_id)
                end
              end
            end

            # REDO committed transactions
            redo_records = records.select do |r|
              committed_transactions.include?(r.transaction_id) &&
              [:insert, :update, :delete, :create_table, :drop_table].include?(r.type)
            end

            redo_records.each do |record|
              replay_record(record)
            end

            # UNDO uncommitted transactions
            uncommitted = records.select do |r|
              !committed_transactions.include?(r.transaction_id) &&
              [:insert, :update, :delete].include?(r.type)
            end

            uncommitted.reverse_each do |record|
              undo_record(record)
            end
          end

          true
        end
      end

      def flush
        @lock.synchronize do
          @writer.flush
        end
      end

      def sync
        @lock.synchronize do
          @writer.sync
        end
      end

      def shutdown(wait = true)
        @lock.synchronize do
          @shutdown = true
          @running = false

          @checkpoint.stop if @checkpoint
          @writer.shutdown(wait)
          @reader.close if @reader
        end
      end

      def running?
        @running
      end

      def stats
        @lock.synchronize do
          writer_stats = @writer.stats rescue {}
          reader_stats = @reader.stats rescue {}
          checkpoint_stats = @checkpoint.stats rescue {}
          archive_stats = @archive.stats rescue {}

          @stats.merge({
            writer: writer_stats,
            reader: reader_stats,
            checkpoint: checkpoint_stats,
            archive: archive_stats,
            current_lsn: @current_lsn.to_s,
            running: @running,
            wal_dir: @wal_dir
          })
        end
      end

      private

      def initialize_components(config)
        @writer = Writer.new(@wal_dir, config)
        @reader = Reader.new(@wal_dir, config)
        @checkpoint = Checkpoint.new(@writer, config)
        @archive = Archive.new(@wal_dir, config[:archive_dir], config)
      end

      def can_commit_prepared?(record)
        data = record&.data
        resources = data && data[:resources]
        return true unless resources

        Array(resources).all? do |resource|
          case resource
          when String then File.exist?(resource)
          when Hash
            path = resource[:path] || resource["path"] || resource[:file] || resource["file"]
            path && File.exist?(path)
          else
            resource.respond_to?(:available?) && resource.available?
          end
        end
      end

      def replay_record(record)
        engine = @engine
        raise RubyDB::RecoveryError, "WAL replay requires an attached engine" unless engine
        data = record.data

        case record.type
        when :insert
          # Insert row
          engine.insert_row(
            data[:table],
            data[:columns],
            data[:values]
          )
        when :update
          # Update row
          engine.update_row(
            data[:table],
            data[:row_id],
            data[:values]
          )
        when :delete
          # Delete row
          engine.delete_row(
            data[:table],
            data[:row_id]
          )
        when :create_table
          # Create table
          engine.create_table(
            data[:table_name],
            data[:columns]
          )
        when :drop_table
          # Drop table
          engine.drop_table(
            data[:table_name]
          )
        end
      end

      def undo_record(record)
        engine = @engine
        raise RubyDB::RecoveryError, "WAL undo requires an attached engine" unless engine
        data = record.data

        case record.type
        when :insert
          # Delete the inserted row
          engine.delete_row(
            data[:table],
            data[:row_id]
          )
        when :update
          # Restore old values
          engine.update_row(
            data[:table],
            data[:row_id],
            data[:old_values]
          )
        when :delete
          # Reinsert the deleted row
          engine.insert_row(
            data[:table],
            data[:columns],
            data[:row_data]
          )
        end
      end
    end
  end
end
