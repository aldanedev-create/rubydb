# frozen_string_literal: true

require "time"

module RubyDB
  module WAL
    # Checkpoint - Manages checkpoints for recovery
    class Checkpoint
      attr_reader :last_checkpoint_lsn, :stats

      def initialize(wal_writer, config = {})
        @wal_writer = wal_writer
        @config = config
        @checkpoint_interval = config[:interval] || 300  # 5 minutes
        @min_checkpoint_age = config[:min_age] || 60    # 1 minute
        @last_checkpoint_time = Time.now
        @last_checkpoint_lsn = nil
        @last_checkpoint_data = nil
        @stats = {
          checkpoints_created: 0,
          checkpoints_restored: 0,
          checkpoint_failures: 0,
          total_checkpoint_time_ms: 0,
          avg_checkpoint_time_ms: 0,
          last_checkpoint_size: 0
        }
        @lock = Mutex.new
        @running = false
        @checkpoint_thread = nil
      end

      def start
        @lock.synchronize do
          return if @running

          @running = true
          @checkpoint_thread = Thread.new do
            checkpoint_loop
          end
        end
      end

      def stop
        @lock.synchronize do
          @running = false
          @checkpoint_thread&.kill
          @checkpoint_thread = nil
        end
      end

      def create_checkpoint(force = false)
        @lock.synchronize do
          start_time = Time.now

          # Check if enough time has passed
          if !force && (Time.now - @last_checkpoint_time) < @min_checkpoint_age
            return false
          end

          begin
            # Flush WAL
            @wal_writer.flush

            # Get current LSN
            current_lsn = @wal_writer.current_lsn

            # Create checkpoint record
            checkpoint_data = {
              lsn: current_lsn.to_s,
              timestamp: Time.now.iso8601,
              wal_segment: @wal_writer.current_segment.segment_id,
              wal_offset: current_lsn.offset
            }

            # Write checkpoint record to WAL
            record = Record.new(:checkpoint, checkpoint_data)
            @wal_writer.write_record(record)

            # Update checkpoint info
            @last_checkpoint_lsn = current_lsn
            @last_checkpoint_data = checkpoint_data
            @last_checkpoint_time = Time.now

            elapsed_ms = (Time.now - start_time) * 1000
            @stats[:checkpoints_created] += 1
            @stats[:total_checkpoint_time_ms] += elapsed_ms
            @stats[:avg_checkpoint_time_ms] = @stats[:total_checkpoint_time_ms] / @stats[:checkpoints_created]
            @stats[:last_checkpoint_size] = estimate_checkpoint_size

            true

          rescue => e
            @stats[:checkpoint_failures] += 1
            raise
          end
        end
      end

      def restore_checkpoint(reader)
        @lock.synchronize do
          start_time = Time.now

          begin
            # Find the latest checkpoint in the WAL
            all_records = reader.read_all
            checkpoint_records = all_records.select { |r| r.type == :checkpoint }

            if checkpoint_records.empty?
              return nil
            end

            # Get the latest checkpoint
            latest = checkpoint_records.last
            @last_checkpoint_lsn = LSN.from_s(latest.data[:lsn])
            @last_checkpoint_data = latest.data
            @last_checkpoint_time = Time.parse(latest.data[:timestamp])

            @stats[:checkpoints_restored] += 1
            @last_checkpoint_lsn

          rescue => e
            @stats[:checkpoint_failures] += 1
            raise
          end
        end
      end

      def checkpoint_exists?
        !@last_checkpoint_lsn.nil?
      end

      def checkpoint_age
        return nil unless @last_checkpoint_lsn
        Time.now - @last_checkpoint_time
      end

      def stats
        @lock.synchronize do
          @stats.merge({
            running: @running,
            last_checkpoint: @last_checkpoint_time.iso8601,
            last_checkpoint_lsn: @last_checkpoint_lsn&.to_s,
            checkpoint_age: checkpoint_age,
            interval: @checkpoint_interval,
            min_age: @min_checkpoint_age
          })
        end
      end

      private

      def checkpoint_loop
        while @running
          sleep(@checkpoint_interval)
          begin
            create_checkpoint
          rescue => e
            # Log error but continue
          end
        end
      end

      def estimate_checkpoint_size
        # Estimate the size of the checkpoint
        # In production, this would calculate actual size
        1024 * 100  # 100KB estimate
      end
    end
  end
end