# frozen_string_literal: true

module RubyDB
  module Storage
    # StorageManager - Central storage management
    class StorageManager
      attr_reader :file_manager, :page_manager, :page_allocator,
                  :buffer_pool, :free_space_map, :visibility_map

      def initialize(path, config = {})
        @path = path
        @page_size = config[:page_size] || Constants::DEFAULT_PAGE_SIZE
        @buffer_size = config[:buffer_size] || Constants::DEFAULT_BUFFER_POOL_SIZE

        # Initialize components
        @file_manager = FileManager.new(path, @page_size)
        @page_manager = PageManager.new(@file_manager)
        @buffer_pool = BufferPool.new(@buffer_size)
        @free_space_map = FreeSpaceMap.new(@page_manager)
        @visibility_map = VisibilityMap.new(@page_manager)
        @page_allocator = PageAllocator.new(@page_manager)

        # Connect components
        @buffer_pool.set_page_manager(@page_manager)

        @is_open = false
        @stats = {
          reads: 0,
          writes: 0,
          allocations: 0,
          frees: 0
        }
      end

      def open
        @file_manager.create_or_open
        @page_manager.load_free_list
        @is_open = true
        self
      rescue => e
        raise StorageError, "Failed to open storage: #{e.message}"
      end

      def close
        return unless @is_open

        flush
        @file_manager.close
        @is_open = false
        true
      end

      def flush
        @buffer_pool.flush_all
        @file_manager.sync
      end

      def read_page(page_number)
        @stats[:reads] += 1
        frame = @buffer_pool.get_page(page_number)
        frame.access
        frame.page
      end

      def write_page(page)
        @stats[:writes] += 1
        @buffer_pool.write_page(page)
      end

      def allocate_page(page_type = 0)
        @stats[:allocations] += 1
        @page_allocator.allocate_page_with_space(0, page_type)
      end

      def free_page(page_number)
        @stats[:frees] += 1
        @page_allocator.release_page(page_number)
        @buffer_pool.remove_page(page_number)
      end

      def read_record(page_number, offset, length)
        page = read_page(page_number)
        page.read(offset, length)
      end

      def write_record(page_number, offset, data)
        page = read_page(page_number)
        page.write(offset, data)
        write_page(page)
      end

      def stats
        {
          page_size: @page_size,
          total_pages: @page_manager.total_pages,
          free_pages: @page_manager.free_pages,
          used_pages: @page_manager.used_pages,
          buffer_hits: @buffer_pool.hit_count,
          buffer_misses: @buffer_pool.miss_count,
          buffer_hit_rate: @buffer_pool.hit_rate,
          reads: @stats[:reads],
          writes: @stats[:writes],
          allocations: @stats[:allocations],
          frees: @stats[:frees]
        }
      end

      def open?
        @is_open
      end
    end
  end
end