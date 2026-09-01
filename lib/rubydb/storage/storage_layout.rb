# frozen_string_literal: true

module RubyDB
  module Storage
    # StorageLayout - Defines the on-disk storage format
    module StorageLayout
      # Magic number for file identification
      MAGIC_NUMBER = "RUBYDB".freeze

      # Current format version
      FORMAT_VERSION = 1

      # Page types
      PAGE_TYPE_SUPERBLOCK = 0
      PAGE_TYPE_FREE = 1
      PAGE_TYPE_TABLE = 2
      PAGE_TYPE_INDEX = 3
      PAGE_TYPE_OVERFLOW = 4
      PAGE_TYPE_INDEX_LEAF = 5
      PAGE_TYPE_INDEX_INTERNAL = 6

      # Superblock layout
      class Superblock
        attr_accessor :magic, :version, :page_size, :num_pages,
                      :root_page, :created_at, :modified_at

        def initialize
          @magic = MAGIC_NUMBER
          @version = FORMAT_VERSION
          @page_size = Constants::DEFAULT_PAGE_SIZE
          @num_pages = 1
          @root_page = 0
          @created_at = Time.now.to_i
          @modified_at = Time.now.to_i
        end

        def serialize
          data = ""
          data << @magic.ljust(16)
          data << [@version, @page_size, @num_pages, @root_page].pack("I>I>Q>Q>")
          data << [@created_at, @modified_at].pack("Q>Q>")
          data
        end

        def self.deserialize(data)
          sb = new
          sb.magic = data[0, 16].strip
          sb.version, sb.page_size, sb.num_pages, sb.root_page = data[16, 16].unpack("I>I>Q>Q>")
          sb.created_at, sb.modified_at = data[32, 16].unpack("Q>Q>")
          sb
        end
      end

      # Table metadata layout
      class TableMetadata
        attr_accessor :table_id, :table_name, :column_count,
                      :row_count, :first_page, :last_page,
                      :created_at, :updated_at

        def initialize
          @table_id = 0
          @table_name = ""
          @column_count = 0
          @row_count = 0
          @first_page = 0
          @last_page = 0
          @created_at = Time.now.to_i
          @updated_at = Time.now.to_i
        end

        def serialize
          data = +""
          data << [@table_id].pack("Q>")
          data << @table_name.to_s.ljust(64)
          data << [@column_count, @row_count].pack("I>Q>")
          data << [@first_page, @last_page].pack("Q>Q>")
          data << [@created_at, @updated_at].pack("Q>Q>")
          data
        end

        def self.deserialize(data)
          tm = new
          tm.table_id = data[0, 8].unpack("Q>").first
          tm.table_name = data[8, 64].strip
          tm.column_count, tm.row_count = data[72, 12].unpack("I>Q>")
          tm.first_page, tm.last_page = data[84, 16].unpack("Q>Q>")
          tm.created_at, tm.updated_at = data[100, 16].unpack("Q>Q>")
          tm
        end
      end

      # Column metadata layout
      class ColumnMetadata
        attr_accessor :column_id, :column_name, :data_type,
                      :is_nullable, :is_primary_key, :position,
                      :default, :created_at

        def initialize
          @column_id = 0
          @column_name = ""
          @data_type = :text
          @is_nullable = true
          @is_primary_key = false
          @position = 0
          @default = nil
          @created_at = Time.now.to_i
        end

        def serialize
          data = +""
          data << [@column_id, @position].pack("I>I>")
          data << @column_name.to_s.ljust(64)
          data << [@data_type.to_s].pack("Z*")
          flags = 0
          flags |= 1 if @is_nullable
          flags |= 2 if @is_primary_key
          data << [flags].pack("C")
          default_payload = @default.nil? ? "" : @default.to_s
          data << default_payload.ljust(64)
          data << [@created_at].pack("Q>")
          data
        end

        def self.deserialize(data)
          cm = new
          cm.column_id, cm.position = data[0, 8].unpack("I>I>")
          cm.column_name = data[8, 64].strip
          cm.data_type = data[72].unpack("Z*").first.to_sym
          flags = data[72 + cm.data_type.to_s.length + 1].unpack("C").first
          cm.is_nullable = (flags & 1) != 0
          cm.is_primary_key = (flags & 2) != 0
          cm.default = data[73 + cm.data_type.to_s.length, 64].strip unless data[73 + cm.data_type.to_s.length, 64].strip.empty?
          cm.created_at = data[137, 8].unpack("Q>").first
          cm
        end
      end

      def self.page_header_size
        PageHeader::SIZE
      end

      def self.record_header_size
        8  # [row_id(4)] + [length(4)]
      end

      def self.max_record_size(page_size)
        page_size - PageHeader::SIZE - 4  # 4 bytes for record pointer
      end
    end
  end
end