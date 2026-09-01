# frozen_string_literal: true

module RubyDB
  module Storage
    # Page - Fixed-size block of storage
    class Page
      attr_reader :page_number, :size, :data, :dirty

      def initialize(page_number, size = Constants::DEFAULT_PAGE_SIZE)
        @page_number = page_number
        @size = size
        @data = "\x00".b * size
        @dirty = false
        @header = PageHeader.new
        @header.page_number = page_number
        @header.page_size = size
      end

      def read(offset, length)
        @data[offset, length]
      end

      def write(offset, data)
        @data[offset, data.bytesize] = data
        @dirty = true
      end

      def write_header
        serialized = @header.serialize
        @data[0, serialized.bytesize] = serialized
        @dirty = true
      end

      def read_header
        header_data = @data[0, PageHeader::SIZE]
        @header = PageHeader.deserialize(header_data)
      end

      def header
        @header
      end

      def free_space
        @size - (@header.header_size + @header.data_end)
      end

      def used_space
        @header.data_end - @header.header_size
      end

      def is_empty?
        @header.data_end <= @header.header_size
      end

      def is_full?
        free_space == 0
      end

      def reset
        @data = "\x00".b * @size
        @dirty = true
        @header = PageHeader.new
        @header.page_number = @page_number
        @header.page_size = @size
        write_header
      end

      def serialize
        {
          page_number: @page_number,
          size: @size,
          data: @data,
          header: @header.serialize
        }
      end

      def self.deserialize(data)
        page_data = data[:data]
        page = new(data[:page_number], data[:size])
        page.instance_variable_set(:@data, page_data)
        page.read_header
        page
      end

      def to_s
        "Page(#{@page_number}) size=#{@size} used=#{used_space} free=#{free_space}"
      end

      def inspect
        to_s
      end
    end
  end
end