# frozen_string_literal: true

module RubyDB
  module Storage
    # FreeSpaceMap - Tracks free space on each page
    class FreeSpaceMap
      def initialize(page_manager)
        @page_manager = page_manager
        @free_space = {}
        @lock = Mutex.new
        load_free_space
      end

      def update_page(page_number, free_space)
        @lock.synchronize do
          @free_space[page_number] = free_space
        end
      end

      def get_free_space(page_number)
        @lock.synchronize do
          @free_space[page_number] || 0
        end
      end

      def find_page_with_space(needed_bytes)
        @lock.synchronize do
          # Find page with enough free space
          best_page = nil
          best_space = Float::INFINITY

          @free_space.each do |page_number, free_space|
            if free_space >= needed_bytes && free_space < best_space
              best_page = page_number
              best_space = free_space
            end
          end

          best_page
        end
      end

      def remove_page(page_number)
        @lock.synchronize do
          @free_space.delete(page_number)
        end
      end

      def total_free_space
        @lock.synchronize do
          @free_space.values.sum
        end
      end

      def load_free_space
        @lock.synchronize do
          @free_space.clear

          (1...@page_manager.total_pages).each do |page_number|
            begin
              page = @page_manager.get_page(page_number)
              @free_space[page_number] = page.free_space
            rescue => e
              # Ignore errors
            end
          end
        end
      end

      def page_free_space_percentage(page_number)
        total = @page_manager.file_manager.page_size
        free = get_free_space(page_number)
        (free.to_f / total * 100).round(2)
      end

      def to_s
        "FreeSpaceMap: #{@free_space.size} pages, total free space: #{total_free_space}"
      end
    end
  end
end