# frozen_string_literal: true

module RubyDB
  module Storage
    # PageHeader - Metadata for a page
    class PageHeader
      SIZE = 64  # Fixed header size

      attr_accessor :page_number, :page_size, :header_size, :data_end,
                   :flags, :checksum, :version, :page_type, :next_page,
                   :prev_page, :free_start, :free_end

      def initialize
        @page_number = 0
        @page_size = Constants::DEFAULT_PAGE_SIZE
        @header_size = SIZE
        @data_end = SIZE
        @flags = 0
        @checksum = 0
        @version = 1
        @page_type = 0  # 0=normal, 1=index, 2=overflow, 3=free
        @next_page = 0
        @prev_page = 0
        @free_start = SIZE
        @free_end = @page_size
      end

      def flags=(value)
        @flags = value
      end

      def page_type=(value)
        @page_type = value
      end

      def serialize
        [
          @page_number, @page_size, @header_size, @data_end,
          @flags, @checksum, @version, @page_type,
          @next_page, @prev_page, @free_start, @free_end
        ].pack("Q>Q>I>I>I>I>I>I>Q>Q>I>I")
      end

      def self.deserialize(data)
        header = new
        values = data.unpack("Q>Q>I>I>I>I>I>I>Q>Q>I>I")
        header.page_number = values[0]
        header.page_size = values[1]
        header.header_size = values[2]
        header.data_end = values[3]
        header.flags = values[4]
        header.checksum = values[5]
        header.version = values[6]
        header.page_type = values[7]
        header.next_page = values[8]
        header.prev_page = values[9]
        header.free_start = values[10]
        header.free_end = values[11]
        header
      end

      def to_s
        "PageHeader(page=#{@page_number}, type=#{@page_type}, data_end=#{@data_end})"
      end
    end
  end
end