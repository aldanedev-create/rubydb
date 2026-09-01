# frozen_string_literal: true

module RubyDB
  module Chaos
    # DiskFull - Simulates disk full conditions
    class DiskFull
      attr_reader :stats

      def initialize(engine, config = {})
        @engine = engine
        @config = config
        @disk_full_probability = config[:probability] || 0.05
        @max_disk_usage = config[:max_usage] || 95 # percentage
        @recovery_enabled = config[:recovery] != false
        @stats = {
          disk_full_events: 0,
          recovery_attempts: 0,
          successful_recoveries: 0,
          failed_recoveries: 0,
          last_event: nil,
          current_usage: 0,
          files_affected: []
        }
        @lock = Mutex.new
        @simulate_disk_full = false
        @test_directory = config[:test_directory] || "tmp/disk_test"
        @file_size_limit = config[:file_size_limit] || 10 * 1024 * 1024 # 10MB

        FileUtils.mkdir_p(@test_directory) unless Dir.exist?(@test_directory)
      end

      def inject
        @lock.synchronize do
          if should_trigger?
            perform_disk_full
          end
        end
      end

      def trigger_disk_full
        @lock.synchronize do
          perform_disk_full
        end
      end

      def clear_disk_full
        @lock.synchronize do
          @simulate_disk_full = false
          @stats[:current_usage] = 0

          # Clean test files
          if Dir.exist?(@test_directory)
            FileUtils.rm_rf(Dir.glob(File.join(@test_directory, "*")))
          end

          @stats[:recovery_attempts] += 1
          if @recovery_enabled && @engine.respond_to?(:recover)
            begin
              @engine.recover
              @stats[:successful_recoveries] += 1
            rescue => e
              @stats[:failed_recoveries] += 1
            end
          end
        end
      end

      def stats
        @lock.synchronize do
          @stats.merge({
            disk_full_probability: @disk_full_probability,
            max_disk_usage: @max_disk_usage,
            recovery_enabled: @recovery_enabled,
            test_directory: @test_directory,
            simulating: @simulate_disk_full
          })
        end
      end

      private

      def should_trigger?
        rand < @disk_full_probability && !@simulate_disk_full
      end

      def perform_disk_full
        @stats[:disk_full_events] += 1
        @stats[:last_event] = Time.now
        @simulate_disk_full = true
        @stats[:current_usage] = @max_disk_usage

        # Create files to simulate disk full
        create_disk_full_files

        # Throw disk full error
        raise ChaosError, "Disk full: #{@max_disk_usage}% usage simulated"
      end

      def create_disk_full_files
        # Create files to simulate disk full
        file_count = (rand(5..20))
        file_count.times do |i|
          file_path = File.join(@test_directory, "test_file_#{i}.dat")
          size = rand(1024..@file_size_limit / file_count)
          File.write(file_path, SecureRandom.random_bytes(size))
          @stats[:files_affected] << file_path
        end

        # Update disk usage stats
        total_size = @stats[:files_affected].sum { |f| File.size(f) if File.exist?(f) }.to_i
        @stats[:current_usage] = [total_size / @file_size_limit * 100, @max_disk_usage].min
      end
    end
  end
end