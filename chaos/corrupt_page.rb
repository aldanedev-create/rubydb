# frozen_string_literal: true

require "securerandom"

module RubyDB
  module Chaos
    # CorruptPage - Corrupts database pages
    class CorruptPage
      attr_reader :stats

      def initialize(engine, config = {})
        @engine = engine
        @config = config
        @corruption_probability = config[:probability] || 0.05
        @max_corruptions = config[:max_corruptions] || 5
        @corruption_types = [:random_bytes, :zero_page, :flip_bits, :truncate, :corrupt_header]
        @stats = {
          corruptions: 0,
          repaired: 0,
          failed_repairs: 0,
          pages_corrupted: [],
          last_corruption: nil
        }
        @lock = Mutex.new
      end

      def inject(page_number = nil)
        @lock.synchronize do
          return if @stats[:corruptions] >= @max_corruptions

          page_number ||= rand(0...@engine.page_manager.total_pages)
          return unless page_exists?(page_number)

          if rand < @corruption_probability
            perform_corruption(page_number)
          end
        end
      end

      def inject_on_page(page_number)
        @lock.synchronize do
          return unless page_exists?(page_number)
          perform_corruption(page_number)
        end
      end

      def corrupt_random_pages(count = 1)
        @lock.synchronize do
          count.times do
            page_number = rand(0...@engine.page_manager.total_pages)
            perform_corruption(page_number) if page_exists?(page_number)
          end
        end
      end

      def repair_page(page_number)
        @lock.synchronize do
          return false unless @stats[:pages_corrupted].include?(page_number)

          begin
            # Attempt to repair page
            page = @engine.read_page(page_number)
            page.header.checksum = calculate_checksum(page.data)
            page.write_header
            @engine.write_page(page)

            @stats[:pages_corrupted].delete(page_number)
            @stats[:repaired] += 1
            true
          rescue => e
            @stats[:failed_repairs] += 1
            false
          end
        end
      end

      def repair_all
        @lock.synchronize do
          @stats[:pages_corrupted].dup.each do |page_number|
            repair_page(page_number)
          end
        end
      end

      def stats
        @lock.synchronize do
          @stats.merge({
            corruption_probability: @corruption_probability,
            max_corruptions: @max_corruptions,
            total_pages: @engine.page_manager.total_pages
          })
        end
      end

      private

      def page_exists?(page_number)
        page_number < @engine.page_manager.total_pages
      end

      def perform_corruption(page_number)
        @stats[:corruptions] += 1
        @stats[:last_corruption] = Time.now
        @stats[:pages_corrupted] << page_number unless @stats[:pages_corrupted].include?(page_number)

        page = @engine.read_page(page_number)
        corruption_type = @corruption_types.sample

        case corruption_type
        when :random_bytes
          corrupt_random_bytes(page)
        when :zero_page
          corrupt_zero_page(page)
        when :flip_bits
          corrupt_flip_bits(page)
        when :truncate
          corrupt_truncate(page)
        when :corrupt_header
          corrupt_header(page)
        end

        @engine.write_page(page)

        # Log corruption
        log_corruption(page_number, corruption_type)
      end

      def corrupt_random_bytes(page)
        offset = rand(0...page.size)
        length = rand(1..[100, page.size - offset].min)
        random_data = SecureRandom.random_bytes(length)
        page.write(offset, random_data)
      end

      def corrupt_zero_page(page)
        # Zero out a section of the page
        offset = rand(0...page.size)
        length = rand(1..[1000, page.size - offset].min)
        page.write(offset, "\x00" * length)
      end

      def corrupt_flip_bits(page)
        offset = rand(0...page.size)
        byte = page.read(offset, 1).unpack("C").first
        flipped = byte ^ (1 << rand(0..7))
        page.write(offset, [flipped].pack("C"))
      end

      def corrupt_truncate(page)
        # Truncate page data
        new_size = rand(page.size / 2..page.size - 1)
        page.instance_variable_set(:@data, page.data[0...new_size])
        page.dirty = true
      end

      def corrupt_header(page)
        # Corrupt page header
        offset = rand(0...PageHeader::SIZE)
        byte = page.read(offset, 1).unpack("C").first
        flipped = byte ^ (1 << rand(0..7))
        page.write(offset, [flipped].pack("C"))
      end

      def calculate_checksum(data)
        Digest::SHA256.hexdigest(data)[0...16]
      end

      def log_corruption(page_number, type)
        # Log corruption details
        @stats[:last_corruption_details] = {
          page: page_number,
          type: type,
          time: Time.now
        }
      end
    end
  end
end