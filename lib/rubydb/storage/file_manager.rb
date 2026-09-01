# frozen_string_literal: true

require "fileutils"

module RubyDB
  module Storage
    # FileManager - Handles low-level file I/O
    class FileManager
      attr_reader :path, :page_size, :file, :file_size, :num_pages

      def initialize(path, page_size = Constants::DEFAULT_PAGE_SIZE)
        @path = path
        @page_size = page_size
        @file = nil
        @file_size = 0
        @num_pages = 0
        @read_only = false
        @is_open = false
      end

      def create_or_open
        exists = File.exist?(@path)

        if exists
          @file = File.open(@path, "r+b")
          @file_size = @file.size
          @num_pages = @file_size / @page_size
          validate_file
        else
          @file = File.open(@path, "w+b")
          @file_size = 0
          @num_pages = 0
          initialize_file
        end

        @is_open = true
        self
      rescue SystemCallError => e
        raise StorageError, "Failed to open database file: #{e.message}"
      end

      def read_page(page_number)
        raise StorageError, "File not open" unless @is_open
        raise StorageError, "Invalid page number: #{page_number}" if page_number >= @num_pages

        @file.seek(page_number * @page_size)
        data = @file.read(@page_size)

        if data.nil? || data.bytesize != @page_size
          raise CorruptError, "Failed to read page #{page_number}"
        end

        data
      end

      def write_page(page_number, data)
        raise StorageError, "File not open" unless @is_open
        raise StorageError, "File is read-only" if @read_only
        raise StorageError, "Invalid page number: #{page_number}" if page_number >= @num_pages
        raise StorageError, "Data size mismatch" if data.bytesize != @page_size

        @file.seek(page_number * @page_size)
        @file.write(data)
        @file.flush
      rescue SystemCallError => e
        raise StorageError, "Failed to write page: #{e.message}"
      end

      def extend_file(num_pages = 1)
        raise StorageError, "File not open" unless @is_open
        raise StorageError, "File is read-only" if @read_only

        new_size = (@num_pages + num_pages) * @page_size
        @file.truncate(new_size)
        @file_size = new_size
        @num_pages += num_pages
        @num_pages
      rescue SystemCallError => e
        raise StorageError, "Failed to extend file: #{e.message}"
      end

      def truncate_file(num_pages)
        raise StorageError, "File not open" unless @is_open
        raise StorageError, "File is read-only" if @read_only

        new_size = num_pages * @page_size
        @file.truncate(new_size)
        @file_size = new_size
        @num_pages = num_pages
        @num_pages
      rescue SystemCallError => e
        raise StorageError, "Failed to truncate file: #{e.message}"
      end

      def close
        return unless @is_open

        @file.close if @file
        @is_open = false
        true
      end

      def sync
        @file.fsync if @file
      rescue SystemCallError => e
        raise StorageError, "Failed to sync file: #{e.message}"
      end

      def read_only?
        @read_only
      end

      def open?
        @is_open
      end

      private

      def initialize_file
        # Write initial superblock page
        superblock = Page.new(0, @page_size)
        superblock.write_header
        write_page(0, superblock.data)
        @num_pages = 1
        @file_size = @page_size
      end

      def validate_file
        # Check file size is multiple of page size
        if @file_size % @page_size != 0
          raise CorruptError, "File size is not a multiple of page size"
        end

        # Read and validate superblock
        begin
          data = read_page(0)
          # Quick validation - check first few bytes
          if data[0, 8] != [0].pack("Q>")
            raise CorruptError, "Invalid superblock"
          end
        rescue => e
          raise CorruptError, "File validation failed: #{e.message}"
        end
      end
    end
  end
end