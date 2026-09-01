# frozen_string_literal: true

module RubyDB
  module Storage
    # Record - A single record stored on a page
    class Record
      attr_reader :page_number, :offset, :length, :data
      attr_accessor :row_id

      def initialize(page_number, offset, length, data = nil)
        @page_number = page_number
        @offset = offset
        @length = length
        @data = data || "\x00".b * length
        @row_id = nil
        @dirty = false
        @deleted = false
      end

      def read(storage_manager)
        return @data unless @data.nil?

        @data = storage_manager.read_record(@page_number, @offset, @length)
        @data
      end

      def write(storage_manager)
        return unless @dirty

        storage_manager.write_record(@page_number, @offset, @data)
        @dirty = false
      end

      def mark_deleted
        @deleted = true
        @dirty = true
      end

      def deleted?
        @deleted
      end

      def update(new_data)
        @data = new_data
        @length = new_data.bytesize
        @dirty = true
      end

      def to_s
        "Record(row_id=#{@row_id}, page=#{@page_number}, offset=#{@offset}, length=#{@length}, deleted=#{@deleted})"
      end

      def inspect
        to_s
      end
    end
  end
end