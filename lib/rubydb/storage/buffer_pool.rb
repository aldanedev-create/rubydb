# frozen_string_literal: true

module RubyDB
  module Storage
    # BufferPool - Caches pages in memory
    class BufferPool
      attr_reader :size, :hit_count, :miss_count

      def initialize(size = Constants::DEFAULT_BUFFER_POOL_SIZE)
        @size = size
        @frames = {}
        @lru_list = []
        @hit_count = 0
        @miss_count = 0
        @lock = Mutex.new
        @page_manager = nil
      end

      def set_page_manager(page_manager)
        @page_manager = page_manager
      end

      def get_page(page_number)
        @lock.synchronize do
          if @frames.key?(page_number)
            @hit_count += 1
            touch_page(page_number)
            return @frames[page_number]
          end

          @miss_count += 1

          # Evict if necessary
          if @frames.size >= @size
            evict_page
          end

          # Load from disk
          page = @page_manager.get_page(page_number)
          frame = BufferFrame.new(page)

          @frames[page_number] = frame
          @lru_list.unshift(page_number)

          frame
        end
      end

      def write_page(page)
        @lock.synchronize do
          if @frames.key?(page.page_number)
            frame = @frames[page.page_number]
            frame.dirty = true
            frame.page = page
            touch_page(page.page_number)
          else
            # Write directly to disk
            @page_manager.write_page(page)
          end
        end
      end

      def flush_all
        @lock.synchronize do
          @frames.each do |page_number, frame|
            if frame.dirty
              @page_manager.write_page(frame.page)
              frame.dirty = false
            end
          end
        end
      end

      def flush_page(page_number)
        @lock.synchronize do
          if @frames.key?(page_number) && @frames[page_number].dirty
            @page_manager.write_page(@frames[page_number].page)
            @frames[page_number].dirty = false
          end
        end
      end

      def remove_page(page_number)
        @lock.synchronize do
          @frames.delete(page_number)
          @lru_list.delete(page_number)
        end
      end

      def clear
        @lock.synchronize do
          flush_all
          @frames.clear
          @lru_list.clear
        end
      end

      def size
        @frames.size
      end

      def hit_rate
        total = @hit_count + @miss_count
        return 0.0 if total == 0
        @hit_count.to_f / total
      end

      def stats
        {
          size: @frames.size,
          max_size: @size,
          hit_count: @hit_count,
          miss_count: @miss_count,
          hit_rate: hit_rate
        }
      end

      private

      def touch_page(page_number)
        @lru_list.delete(page_number)
        @lru_list.unshift(page_number)
      end

      def evict_page
        # Find a clean page to evict (LRU)
        evict_candidates = @lru_list.reverse

        evict_candidates.each do |page_number|
          frame = @frames[page_number]
          next if frame.dirty

          # Evict this page
          @frames.delete(page_number)
          @lru_list.delete(page_number)
          return true
        end

        # If all pages are dirty, force flush the least recently used
        if @lru_list.any?
          page_number = @lru_list.last
          frame = @frames[page_number]
          @page_manager.write_page(frame.page)
          frame.dirty = false

          @frames.delete(page_number)
          @lru_list.delete(page_number)
          return true
        end

        false
      end
    end
  end
end