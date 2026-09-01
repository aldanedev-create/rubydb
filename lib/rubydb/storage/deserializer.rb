# frozen_string_literal: true

require "json"
require "bigdecimal"
require "date"
require "time"

module RubyDB
  module Storage
    # Deserializer - Converts binary format to Ruby objects with full type support
    class Deserializer
      # Deserialize a single value based on its type
      def self.deserialize(data, type, options = {})
        return nil if data.nil? || data.empty?
        
        type_obj = Types::TypeRegistry.lookup(type)
        type_obj.deserialize(data)
      rescue => e
        raise CorruptionError, "Failed to deserialize value of type #{type}: #{e.message}"
      end

      # Deserialize a full row from binary data
      def self.deserialize_row(data, columns, options = {})
        return {} if data.nil? || data.empty?
        
        row = {}
        offset = 0
        fixed_sizes = { integer: 4, bigint: 8, smallint: 2, float: 8, boolean: 1, date: 8, time: 8, timestamp: 8 }
        
        columns.each_with_index do |col, idx|
          begin
            col_type = col.type_class
            col_name = col.name
            has_default = col.has_default?
            
            # Check if fixed-size type
            if fixed_sizes.key?(col_type)
              length = fixed_sizes[col_type]
              if offset + length <= data.bytesize
                value_data = data[offset, length]
                offset += length
                row[col_name] = deserialize(value_data, col_type)
              else
                row[col_name] = has_default ? col.default : nil
              end
            else
              # Variable length - for last column, take remaining data
              if idx == columns.size - 1
                value_data = data[offset..-1]
                row[col_name] = deserialize(value_data, col_type) if value_data.bytesize > 0
                row[col_name] ||= (has_default ? col.default : nil)
              else
                row[col_name] = has_default ? col.default : nil
              end
            end
          rescue => e
            row[col_name] = col.default if col.has_default?
            row[col_name] = nil if col.nullable?
            unless row[col_name]
              raise CorruptionionError, "Failed to deserialize column '#{col_name}': #{e.message}"
            end
          end
        end
        
        row
      end

      # Deserialize a row with a header
      def self.deserialize_row_with_header(data, columns)
        return nil if data.nil? || data.empty?
        
        # Parse header
        header_data = deserialize_header(data)
        
        # Extract row data (after header)
        row_data = data[header_data[:header_size]..-1]
        
        # Deserialize row
        row = deserialize_row(row_data, columns, has_length_prefix: true)
        
        # Add header info to row
        row[:_row_id] = header_data[:row_id]
        row[:_timestamp] = header_data[:timestamp]
        row[:_version] = header_data[:version]
        
        row
      end

      # Deserialize a record header
      def self.deserialize_header(data)
        return { header_size: 0 } if data.nil? || data.bytesize < 16
        
        header_size = 0
        
        # Parse row header
        row_id, version, timestamp, flags, column_count = data.unpack("Q>Q>Q>C>S")
        header_size = 8 + 8 + 8 + 1 + 2  # row_id(8) + version(8) + timestamp(8) + flags(1) + column_count(2)
        
        {
          row_id: row_id,
          version: version,
          timestamp: timestamp,
          flags: flags,
          column_count: column_count,
          header_size: header_size
        }
      rescue => e
        { header_size: 0, error: e.message }
      end

      # Deserialize table metadata
      def self.deserialize_metadata(data)
        return {} if data.nil? || data.empty?
        
        begin
          JSON.parse(data.force_encoding("UTF-8"), symbolize_names: true)
        rescue JSON::ParserError => e
          # Try to handle different encodings
          begin
            JSON.parse(data.force_encoding("ASCII-8BIT"), symbolize_names: true)
          rescue JSON::ParserError
            {}
          end
        end
      end

      # Deserialize page header
      def self.deserialize_page_header(data)
        return nil if data.nil? || data.bytesize < PageHeader::SIZE
        
        PageHeader.deserialize(data)
      end

      # Deserialize a record from a page
      def self.deserialize_record(page, offset, columns)
        return nil if page.nil? || offset.nil?
        
        # Read record header
        record_header = page.read(offset, 16)
        return nil if record_header.nil? || record_header.bytesize < 16
        
        # Parse record header
        record_id, record_size, flags, column_count = record_header.unpack("Q>L>C>S")
        
        # Validate record size
        if record_size <= 0 || record_size > 65535
          raise CorruptionError, "Invalid record size: #{record_size}"
        end
        
        # Read record data
        record_data = page.read(offset + 16, record_size)
        return nil if record_data.nil?
        
        # Deserialize row
        row = deserialize_row(record_data, columns, has_length_prefix: true)
        
        # Add record metadata
        row[:_record_id] = record_id
        row[:_record_size] = record_size
        row[:_flags] = flags
        
        row
      end

      # Deserialize multiple records from a page
      def self.deserialize_records(page, columns, max_records = nil)
        records = []
        offset = PageHeader::SIZE
        count = 0
        
        while offset < page.header.data_end
          break if max_records && count >= max_records
          
          record = deserialize_record(page, offset, columns)
          break if record.nil?
          
          records << record
          offset += 16 + record[:_record_size]
          count += 1
        end
        
        records
      end

      # Deserialize a tuple from binary data
      def self.deserialize_tuple(data, columns)
        return nil if data.nil? || data.empty?
        
        tuple = Tuple.new(columns)
        tuple.deserialize(data)
        tuple
      end

      # Deserialize a value with type and length prefix
      def self.deserialize_value_with_length(data, offset, type)
        return [nil, offset] if data.nil? || offset >= data.bytesize
        
        # Read length prefix (2 bytes)
        if offset + 2 <= data.bytesize
          length = data[offset, 2].unpack("S").first
          offset += 2
          
          if length == 0xFFFF  # NULL marker
            return [nil, offset]
          elsif length > 0 && offset + length <= data.bytesize
            value_data = data[offset, length]
            offset += length
            return [deserialize(value_data, type), offset]
          end
        end
        
        [nil, offset]
      end

      # Deserialize an array of values
      def self.deserialize_array(data, type, count)
        return [] if data.nil? || data.empty? || count <= 0
        
        values = []
        offset = 0
        
        count.times do
          value, new_offset = deserialize_value_with_length(data, offset, type)
          break if new_offset == offset  # No progress
          values << value
          offset = new_offset
        end
        
        values
      end

      # Deserialize a JSON object from binary
      def self.deserialize_json(data)
        return nil if data.nil? || data.empty?
        
        begin
          JSON.parse(data.force_encoding("UTF-8"))
        rescue JSON::ParserError
          nil
        end
      end

      # Deserialize a bitmap
      def self.deserialize_bitmap(data, bit_count)
        return [] if data.nil? || data.empty? || bit_count <= 0
        
        bitmap = []
        data.bytes.each_with_index do |byte, byte_idx|
          (0..7).each do |bit_idx|
            bit_pos = byte_idx * 8 + bit_idx
            break if bit_pos >= bit_count
            bitmap << ((byte >> bit_idx) & 1) == 1
          end
        end
        
        bitmap
      end

      # Deserialize variable-length data with length prefix
      def self.deserialize_variable(data, offset)
        return [nil, offset] if data.nil? || offset >= data.bytesize
        
        if offset + 2 <= data.bytesize
          length = data[offset, 2].unpack("S").first
          offset += 2
          
          if length == 0xFFFF
            return [nil, offset]
          elsif length > 0 && offset + length <= data.bytesize
            value_data = data[offset, length]
            offset += length
            return [value_data, offset]
          end
        end
        
        [nil, offset]
      end

      private

      # Get column length from data
      def self.get_column_length(data, offset, col, columns, idx)
        col_type = col.type_class
        
        # Fixed length types - return their serialized size
        fixed_sizes = {
          integer: 8,
          bigint: 8,
          smallint: 2,
          float: 8,
          boolean: 1,
          date: 8,
          time: 8,
          timestamp: 8
        }
        
        if fixed_sizes.key?(col_type)
          return fixed_sizes[col_type]
        else
          # Variable length (text, json, etc.) - read until end of data or next field boundary
          # For now, consume remaining data if this is the last column
          if idx == columns.size - 1
            return data.bytesize - offset
          else
            # For middle columns, we need a length prefix or a delimiter
            # For simplicity, use remaining data if we don't have more info
            return nil
          end
        end
      end
    end
  end
end