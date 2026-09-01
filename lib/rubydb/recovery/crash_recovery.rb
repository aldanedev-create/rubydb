# frozen_string_literal: true

require "time"
require "set"

module RubyDB
  module Recovery
    # CrashRecovery - Handles recovery from crashes
    class CrashRecovery
      attr_reader :stats, :last_recovery_time

      def initialize(engine, wal, config = {})
        @engine = engine
        @wal = wal
        @config = config
        @last_recovery_time = nil
        @recovery_log = []
        @stats = {
          recoveries: 0,
          redo_records: 0,
          undo_records: 0,
          corrupted_records: 0,
          skipped_records: 0,
          recovery_time_ms: 0,
          avg_recovery_time_ms: 0,
          total_recovery_time_ms: 0
        }
        @lock = Mutex.new
        @stop_on_error = config[:stop_on_error] || true
        @max_errors = config[:max_errors] || 10
      end

      def recover
        @lock.synchronize do
          start_time = Time.now
          @stats[:recoveries] += 1
          @recovery_log.clear
          errors = 0

          begin
            # Step 1: Find the latest checkpoint
            checkpoint_lsn = find_latest_checkpoint
            @recovery_log << { step: "checkpoint", lsn: checkpoint_lsn }

            # Step 2: Read records after checkpoint
            records = if checkpoint_lsn
              @wal.read_from(checkpoint_lsn)
            else
              @wal.read_all
            end

            @recovery_log << { step: "read_records", count: records.size }

            # Step 3: Analyze records for redo/undo
            analysis = analyze_records(records)
            @recovery_log << { step: "analyze", redo: analysis[:redo].size, undo: analysis[:undo].size }

            # Step 4: REDO committed transactions
            redo_count = redo_records(analysis[:redo])
            @stats[:redo_records] += redo_count
            @recovery_log << { step: "redo", count: redo_count }

            # Step 5: UNDO uncommitted transactions
            undo_count = undo_records(analysis[:undo])
            @stats[:undo_records] += undo_count
            @recovery_log << { step: "undo", count: undo_count }

            # Step 6: Verify consistency
            consistency_check = verify_consistency
            @recovery_log << { step: "consistency", passed: consistency_check }

            # Step 7: Create new checkpoint
            if consistency_check
              create_checkpoint_after_recovery
            end

            @last_recovery_time = Time.now
            recovery_time_ms = (Time.now - start_time) * 1000
            @stats[:total_recovery_time_ms] += recovery_time_ms
            @stats[:recovery_time_ms] = recovery_time_ms
            @stats[:avg_recovery_time_ms] = @stats[:total_recovery_time_ms] / @stats[:recoveries]

            {
              success: true,
              redo_count: redo_count,
              undo_count: undo_count,
              consistency_passed: consistency_check,
              recovery_time_ms: recovery_time_ms,
              records_processed: records.size,
              log: @recovery_log
            }

          rescue => e
            @stats[:corrupted_records] += 1
            @recovery_log << { step: "error", error: e.message }

            if @stop_on_error || errors >= @max_errors
              raise
            end

            {
              success: false,
              error: e.message,
              recovery_time_ms: (Time.now - start_time) * 1000,
              log: @recovery_log
            }
          end
        end
      end

      def find_latest_checkpoint
        # Read all records and find the latest checkpoint
        all_records = @wal.read_all rescue []
        checkpoints = all_records.select { |r| r.type == :checkpoint }
        return nil if checkpoints.empty?

        latest = checkpoints.max_by { |r| r.timestamp }
        lsn = latest.lsn

        # Get the LSN from the checkpoint data
        if latest.data && latest.data[:lsn]
          LSN.from_s(latest.data[:lsn])
        else
          lsn
        end
      end

      def analyze_records(records)
        analysis = {
          redo: [],
          undo: [],
          committed: Set.new,
          prepared: Set.new,
          active: Set.new
        }

        # First pass: collect transaction states
        records.each do |record|
          tx_id = record.transaction_id
          case record.type
          when :commit
            analysis[:committed].add(tx_id)
          when :prepare
            analysis[:prepared].add(tx_id)
          when :begin
            analysis[:active].add(tx_id)
          when :rollback
            analysis[:active].delete(tx_id)
          end
        end

        # Determine which transactions to redo and undo
        records.each do |record|
          tx_id = record.transaction_id
          next if tx_id.nil?

          if analysis[:committed].include?(tx_id)
            # Committed transactions need REDO
            if [:insert, :update, :delete, :create_table, :drop_table].include?(record.type)
              analysis[:redo] << record
            end
          elsif analysis[:prepared].include?(tx_id)
            # Prepared but not committed - check if can commit
            if can_commit_prepared?(record)
              analysis[:redo] << record
            else
              analysis[:undo] << record
            end
          elsif analysis[:active].include?(tx_id)
            # Active transactions need UNDO
            if [:insert, :update, :delete].include?(record.type)
              analysis[:undo] << record
            end
          end
        end

        analysis
      end

      def redo_records(records)
        count = 0
        records.each do |record|
          begin
            redo_record(record)
            count += 1
          rescue => e
            @stats[:corrupted_records] += 1
            @recovery_log << { step: "redo_error", record: record.lsn.to_s, error: e.message }
            raise if @stop_on_error
          end
        end
        count
      end

      def undo_records(records)
        count = 0
        # Undo in reverse order
        records.reverse_each do |record|
          begin
            undo_record(record)
            count += 1
          rescue => e
            @stats[:corrupted_records] += 1
            @recovery_log << { step: "undo_error", record: record.lsn.to_s, error: e.message }
            raise if @stop_on_error
          end
        end
        count
      end

      def redo_record(record)
        data = record.data
        case record.type
        when :insert
          # Re-insert the row
          @engine.insert_row(data[:table], data[:columns] || [], data[:values] || {})
        when :update
          # Re-apply the update
          @engine.update_row(data[:table], data[:row_id], data[:values] || {})
        when :delete
          # Re-delete the row
          @engine.delete_row(data[:table], data[:row_id])
        when :create_table
          # Re-create the table
          @engine.create_table(data[:table_name], data[:columns] || [])
        when :drop_table
          # Re-drop the table
          @engine.drop_table(data[:table_name])
        when :schema_change
          # Re-apply schema change
          apply_schema_change(data)
        end
      end

      def undo_record(record)
        data = record.data
        case record.type
        when :insert
          # Undo insert: delete the row
          @engine.delete_row(data[:table], data[:row_id]) if data[:row_id]
        when :update
          # Undo update: restore old values
          if data[:old_values]
            @engine.update_row(data[:table], data[:row_id], data[:old_values])
          end
        when :delete
          # Undo delete: reinsert the row
          if data[:row_data]
            @engine.insert_row(data[:table], data[:columns] || [], data[:row_data])
          end
        end
      end

      def can_commit_prepared?(record)
        # Check if a prepared transaction can be committed
        # In production, this would check if all resources are available
        # and if the transaction is still valid
        data = record.data
        return true unless data && data[:resources]

        # Check if all resources are still available
        data[:resources].all? do |resource|
          resource_available?(resource)
        end
      end

      def resource_available?(resource)
        # Check if a resource is available
        # In production, this would check the actual resource state
        true
      end

      def apply_schema_change(data)
        # Apply schema change
        case data[:operation]
        when :add_column
          table = @engine.find_table(data[:table_name])
          table.add_column(data[:column_name], data[:column_type])
        when :drop_column
          table = @engine.find_table(data[:table_name])
          table.drop_column(data[:column_name])
        when :rename_table
          @engine.rename_table(data[:old_name], data[:new_name])
        end
      end

      def verify_consistency
        # Verify database consistency
        consistency = ConsistencyChecker.new(@engine)
        result = consistency.check_all
        result[:passed]
      end

      def create_checkpoint_after_recovery
        # Create a checkpoint after successful recovery
        @wal.create_checkpoint(true)
      end

      def stats
        @lock.synchronize do
          @stats.merge({
            last_recovery: @last_recovery_time&.iso8601,
            log_entries: @recovery_log.size,
            stop_on_error: @stop_on_error
          })
        end
      end

      def recovery_log
        @recovery_log.dup
      end
    end
  end
end