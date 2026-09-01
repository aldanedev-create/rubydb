# frozen_string_literal: true

module RubyDB
  module Storage
    # PageManager - Manages page allocation and deallocation
    class PageManager
      attr_reader :file_manager

      def initialize(file_manager)
        @file_manager = file_manager
        @free_list = []
        @page_type_map = {}
        @lock = Mutex.new
        load_free_list
      end

      def allocate_page(page_type = 0)
        @lock.synchronize do
          page_number = nil

          # Try to get from free list
          if @free_list.any?
            page_number = @free_list.pop
            @page_type_map[page_number] = page_type
            return page_number
          end

          # Allocate new page
          page_number = @file_manager.num_pages
          @file_manager.extend_file(1)

          # Initialize page
          page = Page.new(page_number, @file_manager.page_size)
          page.header.page_type = page_type
          page.write_header
          @file_manager.write_page(page_number, page.data)

          @page_type_map[page_number] = page_type
          page_number
        end
      end

      def free_page(page_number)
        @lock.synchronize do
          return unless page_exists?(page_number)

          # Clear the page
          page = Page.new(page_number, @file_manager.page_size)
          page.header.page_type = 3  # Free page type
          page.write_header
          @file_manager.write_page(page_number, page.data)

          @free_list << page_number
          @page_type_map.delete(page_number)
          true
        end
      end

      def page_exists?(page_number)
        page_number < @file_manager.num_pages
      end

      def page_type(page_number)
        @page_type_map[page_number] || 0
      end

      def get_page(page_number)
        @lock.synchronize do
          raise StorageError, "Page #{page_number} does not exist" unless page_exists?(page_number)

          data = @file_manager.read_page(page_number)
          page = Page.new(page_number, @file_manager.page_size)
          page.instance_variable_set(:@data, data)
          page.read_header
          page
        end
      end

      def write_page(page)
        @lock.synchronize do
          raise StorageError, "Page #{page.page_number} does not exist" unless page_exists?(page.page_number)

          page.write_header
          @file_manager.write_page(page.page_number, page.data)
          page.instance_variable_set(:@dirty, false)
        end
      end

      def total_pages
        @file_manager.num_pages
      end

      def free_pages
        @free_list.size
      end

      def used_pages
        total_pages - free_pages
      end

      def load_free_list
        # Scan all pages to find free ones
        @free_list = []
        @page_type_map = {}

        (0...@file_manager.num_pages).each do |page_number|
          begin
            data = @file_manager.read_page(page_number)
            header = PageHeader.deserialize(data[0, PageHeader::SIZE])

            if header.page_type == 3  # Free page
              @free_list << page_number
            else
              @page_type_map[page_number] = header.page_type
            end
          rescue => e
            # Ignore errors during free list loading
          end
        end

        # Don't include page 0 (superblock)
        @free_list.delete(0)
        @free_list.sort!
      end

      def flush
        @file_manager.sync
      end
    end
  end
end