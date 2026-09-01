# frozen_string_literal: true

module RubyDB
  module Chaos
    # PartialWrite - Simulates partial writes to disk
    class PartialWrite
      attr_reader :stats

      def initialize(engine, config = {})
        @engine = engine
        @config = config
        @partial_write_probability = config[:probability] || 0.05
        @max_partial_writes = config[:max_writes] || 5
        @write_types = [:truncate_write, :interrupt_write, :corrupt_write, :delayed_write]
        @stats = {
          partial_writes: 0,
          truncates: 0,
          interrupts: 0,
          corrupts: 0,
          delays: 0,
          recovered: 0,
          failed_recoveries: 0,
          last_write: nil,
          pages_affected: []
        }
        @lock = Mutex.new
        @intercept_writes = false
      end

      def inject(page_number = nil)
        @lock.synchronize do
          return if @stats[:partial_writes] >= @max_partial_writes

          if rand < @partial_write_probability
            page_number ||= rand(0...@engine.page_manager.total_pages)
            perform_partial_write(page_number)
          end
        end
      end

      def inject_on_page(page_number)
        @lock.synchronize do
          perform_partial_write(page_number)
        end
      end

      def enable_intercept
        @lock.synchronize do
          @intercept_writes = true
        end
      end

      def disable_intercept
        @lock.synchronize do
          @intercept_writes = false
        end
      end

      def stats
        @lock.synchronize do
          @stats.merge({
            partial_write_probability: @partial_write_probability,
            max_partial_writes: @max_partial_writes,
            intercepting: @intercept_writes
          })
        end
      end

      private

      def perform_partial_write(page_number)
        @stats[:partial_writes] += 1
        @stats[:last_write] = Time.now

        write_type = @write_types.sample

        case write_type
        when :truncate_write
          perform_truncate_write(page_number)
        when :interrupt_write
          perform_interrupt_write(page_number)
        when :corrupt_write
          perform_corrupt_write(page_number)
        when :delayed_write
          perform_delayed_write(page_number)
        end

        @stats[:pages_affected] << page_number unless @stats[:pages_affected].include?(page_number)
      end

      def perform_truncate_write(page_number)
        @stats[:truncates] += 1
        page = @engine.read_page(page_number)
        original_size = page.size

        # Truncate write to half size
        truncated_data = page.data[0...original_size / 2]
        page.write(0, truncated_data)
        @engine.write_page(page)

        # Attempt recovery
        attempt_recovery(page_number)
      end

      def perform_interrupt_write(page_number)
        @stats[:interrupts] += 1
        page = @engine.read_page(page_number)

        # Write data then "interrupt"
        offset = rand(0...page.size)
        length = rand(1..[100, page.size - offset].min)
        page.write(offset, SecureRandom.random_bytes(length))

        # Simulate interrupt by not completing write
        # The page is dirty but not written

        # Attempt recovery
        attempt_recovery(page_number)
      end

      def perform_corrupt_write(page_number)
        @stats[:corrupts] += 1
        page = @engine.read_page(page_number)

        # Write corrupted data
        offset = rand(0...page.size)
        length = rand(1..[1000, page.size - offset].min)
        corrupted = SecureRandom.random_bytes(length)
        page.write(offset, corrupted)
        @engine.write_page(page)

        # Attempt recovery
        attempt_recovery(page_number)
      end

      def perform_delayed_write(page_number)
        @stats[:delays] += 1
        page = @engine.read_page(page_number)

        # Write data with delay
        offset = rand(0...page.size)
        length = rand(1..[100, page.size - offset].min)
        page.write(offset, SecureRandom.random_bytes(length))

        # Simulate delay
        sleep(rand(0.1..0.5))

        @engine.write_page(page)
      end

      def attempt_recovery(page_number)
        if @config[:auto_recovery] != false
          begin
            page = @engine.read_page(page_number)
            page.header.checksum = calculate_checksum(page.data)
            page.write_header
            @engine.write_page(page)
            @stats[:recovered] += 1
          rescue => e
            @stats[:failed_recoveries] += 1
          end
        end
      end

      def calculate_checksum(data)
        Digest::SHA256.hexdigest(data)[0...16]
      end
    end
  end
end