# frozen_string_literal: true

require "stringio"

module RubyDB
  module Storage
    # Tuple - Binary representation of a row for storage with proper variable-length support
    class Tuple
      attr_reader :data, :header, :column_count, :columns, :values, :size

      # Header format:
      # [version(1)] [flags(1)] [null_bitmap(4)] [column_count(2)] [tuple_size(4)]
      # [column_offsets...] (2 bytes each)
      HEADER_SIZE = 12  # Version(1) + Flags(1) + NullBitmap(4) + ColumnCount(2) + TupleSize(4)
      MAX_COLUMNS = 65535
      MAX_TUPLE_SIZE = 65535  # 64KB max tuple size

      def initialize(columns, values = nil)
        @columns = columns
        @values = values ? values.dup : {}
        @header = nil
        @data = nil
        @dirty = true
        @size = 0
        @null_bitmap = 0
        @column_offsets = []
        @column_lengths = []
        @flags = 0
        @version = 1
        @is_compressed = false
        @compression_threshold = 1024  # Compress if data > 1KB
        
        # Validate columns
        raise ArgumentError, "Columns cannot be empty" if @columns.empty?
        raise ArgumentError, "Too many columns (max #{MAX_COLUMNS})" if @columns.size > MAX_COLUMNS
      end

      def serialize
        return @data unless @dirty

        # Calculate null bitmap
        calculate_null_bitmap
        
        # Serialize each column value
        column_data = []
        @column_offsets = []
        @column_lengths = []
        @size = HEADER_SIZE
        total_data = StringIO.new("".b)
        
        @columns.each_with_index do |col, idx|
          value = @values[col.name]
          
          # Check if value is NULL
          is_null = value.nil?
          
          # Serialize the value
          serialized = if is_null
            "".b
          else
            serialize_value(col, value)
          end
          
          # Store offset and length
          @column_offsets[idx] = @size
          @column_lengths[idx] = serialized.bytesize
          
          # Write data
          total_data.write(serialized)
          @size += serialized.bytesize
        end
        
        # Build header
        header_data = build_header
        
        # Combine header and data
        @data = header_data + total_data.string
        
        # Check if compression is needed
        if @data.bytesize > @compression_threshold
          compressed = compress_data(@data)
          if compressed.bytesize < @data.bytesize
            @data = compressed
            @flags |= 0x01  # Set compression flag
            @is_compressed = true
          end
        end
        
        @dirty = false
        @data
      end

      def deserialize(data)
        @data = data
        @is_compressed = false
        
        # Check if data is compressed
        if data.bytesize >= 1
          # Peek at flags
          flags_byte = data[1].unpack("C").first if data.bytesize > 1
          if flags_byte && (flags_byte & 0x01) != 0
            @data = decompress_data(data)
            @is_compressed = true
          end
        end
        
        parse_header(@data)
        parse_column_data(@data)
        
        @dirty = false
        self
      rescue => e
        raise CorruptionError, "Failed to deserialize tuple: #{e.message}"
      end

      def update_value(column_name, value)
        @values[column_name] = value
        @dirty = true
      end

      def update_values(new_values)
        new_values.each do |name, value|
          @values[name] = value
        end
        @dirty = true
      end

      def get_value(column_name)
        @values[column_name]
      end

      def to_row(row_id)
        Row.new(row_id, @columns, @values)
      end

      def to_hash
        @values.dup
      end

      def to_ary
        @columns.map { |col| @values[col.name] }
      end

      def compressed?
        @is_compressed
      end

      def size
        @data ? @data.bytesize : @size
      end

      def column_count
        @columns.size
      end

      def null?(column_name)
        @values[column_name].nil?
      end

      def each_column
        @columns.each do |col|
          yield col, @values[col.name]
        end
      end

      private

      def build_header
        header_data = "".b
        
        # Version (1 byte)
        header_data << [@version].pack("C")
        
        # Flags (1 byte)
        # Bit 0: compressed
        # Bit 1: has nulls
        # Bit 2: has defaults
        flags = @flags
        flags |= 0x02 if has_nulls?
        flags |= 0x04 if has_defaults?
        header_data << [flags].pack("C")
        
        # Null bitmap (4 bytes)
        header_data << [@null_bitmap].pack("L")
        
        # Column count (2 bytes)
        header_data << [@columns.size].pack("S")
        
        # Tuple size (4 bytes)
        header_data << [@size].pack("L")
        
        # Column offsets (2 bytes each)
        @column_offsets.each do |offset|
          header_data << [offset].pack("S")
        end
        
        header_data
      end

      def parse_header(data)
        offset = 0
        
        # Version
        @version = data[offset].unpack("C").first
        offset += 1
        
        # Flags
        @flags = data[offset].unpack("C").first
        offset += 1
        
        # Null bitmap
        @null_bitmap = data[offset, 4].unpack("L").first
        offset += 4
        
        # Column count
        @column_count = data[offset, 2].unpack("S").first
        offset += 2
        
        # Tuple size
        @size = data[offset, 4].unpack("L").first
        offset += 4
        
        # Column offsets
        @column_offsets = []
        @column_lengths = []
        
        @column_count.times do
          @column_offsets << data[offset, 2].unpack("S").first
          offset += 2
        end
        
        # Calculate column lengths
        @column_count.times do |i|
          if i < @column_count - 1
            @column_lengths[i] = @column_offsets[i + 1] - @column_offsets[i]
          else
            @column_lengths[i] = @size - @column_offsets[i]
          end
        end
      end

      def parse_column_data(data)
        @values = {}
        
        @column_count.times do |i|
          col = @columns[i]
          offset = @column_offsets[i]
          length = @column_lengths[i]
          
          # Check if value is NULL
          if null_at?(i)
            @values[col.name] = nil
            next
          end
          
          # Read and deserialize value
          value_data = data[offset, length]
          @values[col.name] = deserialize_value(col, value_data)
        end
      end

      def serialize_value(column, value)
        type_class = column.type_class
        
        # Handle special types
        case type_class
        when :text, :varchar, :char
          value = value.to_s.encode("UTF-8")
          length_prefix = [value.bytesize].pack("S")
          length_prefix + value
          
        when :blob
          value = value.is_a?(String) ? value.b : value.to_s.b
          length_prefix = [value.bytesize].pack("L")
          length_prefix + value
          
        when :json
          value = value.is_a?(Hash) || value.is_a?(Array) ? value : {}
          json_str = JSON.generate(value)
          length_prefix = [json_str.bytesize].pack("S")
          length_prefix + json_str
          
        when :uuid
          # UUID is stored as 16 bytes binary
          if value.nil?
            "\x00" * 16
          else
            str = value.to_s.gsub("-", "")
            [str].pack("H*")
          end
          
        when :decimal
          require "bigdecimal"
          bd = value.is_a?(BigDecimal) ? value : BigDecimal(value.to_s)
          str = bd.to_s("F")
          length_prefix = [str.bytesize].pack("S")
          length_prefix + str
          
        when :date
          if value.nil?
            [0].pack("L")
          else
            days = value - Date.new(1970, 1, 1)
            [days.to_i].pack("L")
          end
          
        when :time
          if value.nil?
            [0].pack("Q")
          else
            seconds = value.hour * 3600 + value.min * 60 + value.sec
            microseconds = value.usec
            total = seconds * 1_000_000 + microseconds
            [total].pack("Q")
          end
          
        when :timestamp
          if value.nil?
            [0].pack("Q")
          else
            [value.to_i].pack("Q")
          end
          
        when :integer
          [value.to_i].pack("l>")
          
        when :bigint
          [value.to_i].pack("q>")
          
        when :smallint
          [value.to_i].pack("s>")
          
        when :float
          [value.to_f].pack("E")
          
        when :boolean
          value ? "\x01".b : "\x00".b
          
        else
          # Unknown type - use string representation
          str = value.to_s
          length_prefix = [str.bytesize].pack("S")
          length_prefix + str
        end
      end

      def deserialize_value(column, data)
        return nil if data.nil? || data.empty?
        
        type_class = column.type_class
        
        case type_class
        when :text, :varchar, :char
          data.force_encoding("UTF-8")
          
        when :blob
          data.b
          
        when :json
          begin
            JSON.parse(data.force_encoding("UTF-8"))
          rescue JSON::ParserError
            {}
          end

        when :uuid
          hex = data.unpack("H*").first
          "#{hex[0...8]}-#{hex[8...12]}-#{hex[12...16]}-#{hex[16...20]}-#{hex[20...32]}"
          
        when :decimal
          require "bigdecimal"
          BigDecimal(data.force_encoding("UTF-8"))
          
        when :date
          require "date"
          days = data.unpack("L").first
          Date.new(1970, 1, 1) + days
          
        when :time
          require "time"
          total = data.unpack("Q").first
          seconds = total / 1_000_000
          microseconds = total % 1_000_000
          hour = seconds / 3600
          minute = (seconds % 3600) / 60
          sec = seconds % 60
          Time.new(1970, 1, 1, hour, minute, sec, microseconds)
          
        when :timestamp
          require "time"
          Time.at(data.unpack("Q").first)
          
        when :integer
          data.unpack("l>").first
          
        when :bigint
          data.unpack("q>").first
          
        when :smallint
          data.unpack("s>").first
          
        when :float
          data.unpack("E").first
          
        when :boolean
          data.unpack("C").first == 1
          
        else
          data.force_encoding("UTF-8")
        end
      end

      def calculate_null_bitmap
        @null_bitmap = 0
        @columns.each_with_index do |col, idx|
          if @values[col.name].nil?
            @null_bitmap |= (1 << idx)
          end
        end
      end

      def null_at?(index)
        (@null_bitmap & (1 << index)) != 0
      end

      def has_nulls?
        @null_bitmap != 0
      end

      def has_defaults?
        @columns.any? { |col| col.has_default? && @values[col.name].nil? }
      end

      def compress_data(data)
        return data if data.bytesize < 100
        
        begin
          require "zlib"
          Zlib::Deflate.deflate(data, Zlib::BEST_SPEED)
        rescue LoadError
          data
        end
      end

      def decompress_data(data)
        begin
          require "zlib"
          Zlib::Inflate.inflate(data)
        rescue LoadError, Zlib::DataError
          data  # Return original if decompression fails
        end
      end

      def validate_tuple_size
        if @size > MAX_TUPLE_SIZE
          raise StorageError, "Tuple size #{@size} exceeds maximum #{MAX_TUPLE_SIZE}"
        end
      end
    end
  end
end
