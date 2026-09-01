# frozen_string_literal: true

require "fileutils"
require "securerandom"

module RubyDB
  module Fuzz
    # WALFuzzer - Fuzz testing for Write-Ahead Log
    class WALFuzzer
      attr_reader :stats

      def initialize(config = {})
        @config = config
        @test_dir = config[:test_dir] || "tmp/fuzz_wal"
        @max_iterations = config[:max_iterations] || 5000
        @seed = config[:seed]
        @stats = {
          total_operations: 0,
          successful_ops: 0,
          failed_ops: 0,
          wal_writes: 0,
          wal_reads: 0,
          checkpoint_operations: 0,
          recovery_operations: 0,
          corruptions: 0,
          errors: 0,
          crashes: 0,
          edge_cases_found: []
        }
        @lock = Mutex.new
        @wal = nil
        @wal_dir = File.join(@test_dir, "wal")

        srand(@seed) if @seed

        # Setup test directory
        FileUtils.rm_rf(@test_dir) if Dir.exist?(@test_dir)
        FileUtils.mkdir_p(@wal_dir)
      end

      def fuzz(iterations = @max_iterations)
        @lock.synchronize do
          # Initialize WAL
          @wal = RubyDB::WAL::WAL.new(@wal_dir, 
            segment_size: 1024 * 1024,  # 1MB
            buffer_size: 1024,
            sync: false,
            auto_checkpoint: false
          )

          iterations.times do |i|
            begin
              @stats[:total_operations] += 1

              # Choose random WAL operation
              operation = choose_operation

              # Execute operation
              result = execute_operation(operation)

              if result[:success]
                @stats[:successful_ops] += 1
                case operation[:type]
                when :write
                  @stats[:wal_writes] += 1
                when :read
                  @stats[:wal_reads] += 1
                when :checkpoint
                  @stats[:checkpoint_operations] += 1
                when :recovery
                  @stats[:recovery_operations] += 1
                end
              else
                @stats[:failed_ops] += 1
                if result[:error] && result[:error].include?("crash")
                  @stats[:crashes] += 1
                  @stats[:edge_cases_found] << {
                    operation: operation,
                    error: result[:error],
                    iteration: i
                  }
                end
              end

            rescue => e
              @stats[:errors] += 1
              @stats[:crashes] += 1
              @stats[:edge_cases_found] << {
                operation: operation,
                error: e.message,
                backtrace: e.backtrace,
                iteration: i
              }
            end

            # Progress reporting
            if i % 100 == 0
              print_progress(i, iterations)
            end
          end

          # Cleanup
          @wal.shutdown if @wal
          FileUtils.rm_rf(@test_dir) if Dir.exist?(@test_dir)

          @stats
        end
      end

      def choose_operation
        rand_num = rand

        if rand_num < 0.2
          { type: :write, record_type: [:insert, :update, :delete, :create_table, :drop_table].sample }
        elsif rand_num < 0.35
          { type: :write_batch, size: rand(2..10) }
        elsif rand_num < 0.50
          { type: :read_all }
        elsif rand_num < 0.60
          { type: :read_range }
        elsif rand_num < 0.70
          { type: :checkpoint }
        elsif rand_num < 0.80
          { type: :recovery }
        elsif rand_num < 0.90
          { type: :corrupt_wal }
        else
          { type: :flush }
        end
      end

      def execute_operation(operation)
        case operation[:type]
        when :write
          execute_wal_write(operation[:record_type])
        when :write_batch
          execute_wal_write_batch(operation[:size])
        when :read_all
          execute_wal_read_all
        when :read_range
          execute_wal_read_range
        when :checkpoint
          execute_checkpoint
        when :recovery
          execute_recovery
        when :corrupt_wal
          execute_corrupt_wal
        when :flush
          execute_flush
        else
          { success: false, error: "Unknown operation" }
        end
      end

      def execute_wal_write(record_type)
        record_data = generate_record_data(record_type)
        record = RubyDB::WAL::Record.new(record_type, record_data, 
          transaction_id: "txn_#{rand(1000)}"
        )
        lsn = @wal.write(record)
        { success: true, lsn: lsn }
      rescue => e
        { success: false, error: e.message }
      end

      def execute_wal_write_batch(size)
        records = []
        size.times do
          record_type = [:insert, :update, :delete].sample
          record_data = generate_record_data(record_type)
          records << RubyDB::WAL::Record.new(record_type, record_data,
            transaction_id: "txn_#{rand(1000)}"
          )
        end
        result = @wal.write_batch(records)
        { success: true, count: result[:count] }
      rescue => e
        { success: false, error: e.message }
      end

      def execute_wal_read_all
        records = @wal.read_all
        { success: true, count: records.size }
      rescue => e
        { success: false, error: e.message }
      end

      def execute_wal_read_range
        # Read from a random LSN range
        start_lsn = RubyDB::WAL::LSN.new(rand(1..10), rand(0..1000))
        end_lsn = RubyDB::WAL::LSN.new(start_lsn.segment_id + rand(1..5), rand(0..1000))
        records = @wal.read_range(start_lsn, end_lsn)
        { success: true, count: records.size }
      rescue => e
        { success: false, error: e.message }
      end

      def execute_checkpoint
        result = @wal.create_checkpoint(true)
        { success: result }
      rescue => e
        { success: false, error: e.message }
      end

      def execute_recovery
        # Simulate crash recovery
        @wal.shutdown
        
        # Corrupt some data if we want
        if rand < 0.1
          corrupt_wal_file
        end

        # Re-initialize and recover
        @wal = RubyDB::WAL::WAL.new(@wal_dir,
          segment_size: 1024 * 1024,
          buffer_size: 1024,
          sync: false,
          auto_checkpoint: false,
          recovery: true
        )
        
        { success: true }
      rescue => e
        { success: false, error: "crash: #{e.message}" }
      end

      def execute_corrupt_wal
        corrupt_wal_file
        @stats[:corruptions] += 1
        { success: true }
      end

      def execute_flush
        @wal.flush
        { success: true }
      rescue => e
        { success: false, error: e.message }
      end

      def generate_record_data(record_type)
        case record_type
        when :insert
          { table: "fuzz_users", row_id: rand(1..1000), values: { name: "fuzz_#{rand(1000)}", age: rand(18..65) } }
        when :update
          { table: "fuzz_users", row_id: rand(1..1000), values: { age: rand(18..65) } }
        when :delete
          { table: "fuzz_users", row_id: rand(1..1000) }
        when :create_table
          { table_name: "fuzz_temp_#{rand(1000)}", columns: ["id INTEGER PRIMARY KEY", "name TEXT", "age INTEGER"] }
        when :drop_table
          { table_name: "fuzz_temp_#{rand(1000)}" }
        else
          { data: "random_data_#{rand(1000)}" }
        end
      end

      def corrupt_wal_file
        wal_files = Dir.glob(File.join(@wal_dir, "wal_*.log"))
        return if wal_files.empty?

        file = wal_files.sample
        return unless File.exist?(file)

        # Corrupt file by overwriting random bytes
        size = File.size(file)
        return if size < 10

        offset = rand(size - 10)
        corrupt_data = SecureRandom.random_bytes(rand(1..10))

        File.open(file, "r+b") do |f|
          f.seek(offset)
          f.write(corrupt_data)
        end
      end

      def stats
        @lock.synchronize do
          @stats.merge({
            test_dir: @test_dir,
            wal_dir: @wal_dir,
            success_rate: @stats[:total_operations] > 0 ?
              (@stats[:successful_ops].to_f / @stats[:total_operations] * 100).round(2) : 0,
            wal_files: Dir.glob(File.join(@wal_dir, "wal_*.log")).size
          })
        end
      end

      def print_progress(current, total)
        percent = (current.to_f / total * 100).round(1)
        bar_length = 40
        filled = (percent / 100 * bar_length).round
        bar = "[" + "=" * filled + " " * (bar_length - filled) + "]"

        print("\rWAL Fuzzing: #{bar} #{percent}% (#{current}/#{total})", nil, false)
        print("\n") if current == total - 1
      end
    end
  end
end