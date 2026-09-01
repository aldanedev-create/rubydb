# frozen_string_literal: true

module RubyDB
  module Recovery
    # RecoveryManager - Main recovery coordination
    class RecoveryManager
      attr_reader :crash_recovery, :checkpoint, :redo, :undo
      attr_reader :consistency_checker, :corruption_detector, :stats

      def initialize(engine, wal, config = {})
        @engine = engine
        @wal = wal
        @config = config

        # Initialize components
        @crash_recovery = CrashRecovery.new(engine, wal, config)
        @checkpoint = Checkpoint.new(engine, wal, config)
        @redo = Redo.new(engine, wal, config)
        @undo = Undo.new(engine, wal, config)
        @consistency_checker = ConsistencyChecker.new(engine, config)
        @corruption_detector = CorruptionDetector.new(engine, config)

        @stats = {
          recoveries_performed: 0,
          checkpoints_created: 0,
          redos_performed: 0,
          undos_performed: 0,
          consistency_checks: 0,
          corruption_detections: 0,
          last_recovery_time: nil,
          last_recovery_result: nil,
          total_recovery_time_ms: 0
        }
        @lock = Mutex.new
        @recovery_mode = config[:recovery_mode] || :auto
        @recovery_states = []
        @max_states = config[:max_states] || 100
      end

      def perform_recovery
        @lock.synchronize do
          start_time = Time.now
          @stats[:recoveries_performed] += 1

          result = {
            success: false,
            steps: [],
            errors: [],
            warnings: [],
            details: {}
          }

          # Step 1: Detect corruption
          corruption_result = @corruption_detector.detect_corruption
          result[:steps] << { step: "corruption_detection", result: corruption_result }

          if corruption_result[:corrupted]
            result[:warnings] << "Corruption detected, attempting repair"

            # Step 2: Repair corruption
            repair_result = @corruption_detector.repair_corruption(corruption_result)
            result[:steps] << { step: "corruption_repair", result: repair_result }

            if repair_result[:repaired]
              result[:details][:repaired] = true
            else
              result[:errors] << "Corruption repair failed"
              @stats[:corruption_detections] += 1
            end
          end

          # Step 3: Run crash recovery
          recovery_result = @crash_recovery.recover
          result[:steps] << { step: "crash_recovery", result: recovery_result }
          @stats[:last_recovery_result] = recovery_result

          if recovery_result[:success]
            result[:details][:redo_count] = recovery_result[:redo_count]
            result[:details][:undo_count] = recovery_result[:undo_count]
          else
            result[:errors] << "Crash recovery failed: #{recovery_result[:error]}"
          end

          # Step 4: Check consistency
          consistency_result = @consistency_checker.check_all
          result[:steps] << { step: "consistency_check", result: consistency_result }
          @stats[:consistency_checks] += 1

          if consistency_result[:passed]
            result[:success] = true
          else
            result[:errors] << "Consistency check failed"
            result[:success] = false
          end

          # Step 5: Create checkpoint if successful
          if result[:success]
            checkpoint_result = @checkpoint.create_checkpoint(true)
            result[:steps] << { step: "checkpoint", result: checkpoint_result }
            @stats[:checkpoints_created] += 1 if checkpoint_result
          end

          # Record state
          record_state(result)

          elapsed_ms = (Time.now - start_time) * 1000
          @stats[:total_recovery_time_ms] += elapsed_ms
          @stats[:last_recovery_time] = Time.now

          result
        end
      end

      def create_checkpoint(force = false)
        @lock.synchronize do
          @checkpoint.create_checkpoint(force)
          @stats[:checkpoints_created] += 1
        end
      end

      def redo_records(records, from_lsn = nil)
        @lock.synchronize do
          count = @redo.redo_records(records, from_lsn)
          @stats[:redos_performed] += 1
          count
        end
      end

      def undo_records(records)
        @lock.synchronize do
          count = @undo.undo_records(records)
          @stats[:undos_performed] += 1
          count
        end
      end

      def check_consistency
        @lock.synchronize do
          result = @consistency_checker.check_all
          @stats[:consistency_checks] += 1
          result
        end
      end

      def detect_corruption(scan_all = false)
        @lock.synchronize do
          result = @corruption_detector.detect_corruption(scan_all)
          @stats[:corruption_detections] += 1 if result[:corrupted]
          result
        end
      end

      def repair_corruption(corruption_info)
        @lock.synchronize do
          @corruption_detector.repair_corruption(corruption_info)
        end
      end

      def recovery_mode
        @recovery_mode
      end

      def recovery_mode=(mode)
        @lock.synchronize do
          @recovery_mode = mode
        end
      end

      def recovery_history
        @recovery_states.dup
      end

      def stats
        @lock.synchronize do
          @stats.merge({
            recovery_mode: @recovery_mode,
            history_size: @recovery_states.size,
            max_states: @max_states,
            crash_recovery: @crash_recovery.stats,
            checkpoint: @checkpoint.stats,
            redo: @redo.stats,
            undo: @undo.stats,
            consistency_checker: @consistency_checker.stats,
            corruption_detector: @corruption_detector.stats
          })
        end
      end

      private

      def record_state(result)
        state = {
          timestamp: Time.now.iso8601,
          result: result,
          stats: @stats.dup
        }

        @recovery_states << state

        if @recovery_states.size > @max_states
          @recovery_states.shift
        end
      end
    end
  end
end