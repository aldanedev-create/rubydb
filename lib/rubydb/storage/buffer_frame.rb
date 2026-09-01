# frozen_string_literal: true

module RubyDB
  module Storage
    # BufferFrame - Holds a page in the buffer pool
    class BufferFrame
      attr_accessor :page, :dirty, :pinned, :access_count

      def initialize(page)
        @page = page
        @dirty = false
        @pinned = 0
        @access_count = 0
        @created_at = Time.now
        @last_access = Time.now
      end

      def pin
        @pinned += 1
      end

      def unpin
        @pinned -= 1 if @pinned > 0
      end

      def pinned?
        @pinned > 0
      end

      def access
        @access_count += 1
        @last_access = Time.now
      end

      def to_s
        "BufferFrame(page=#{@page.page_number}, dirty=#{@dirty}, pinned=#{@pinned}, accesses=#{@access_count})"
      end

      def inspect
        to_s
      end
    end
  end
end