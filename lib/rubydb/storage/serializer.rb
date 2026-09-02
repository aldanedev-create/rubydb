# frozen_string_literal: true

module RubyDB
  module Storage
    # Serializer - Converts Ruby objects to binary format
    class Serializer
      def self.serialize(value, type)
        type_obj = Types::TypeRegistry.lookup(type)
        type_obj.serialize(value)
      end

      def self.serialize_row(row, columns, null_bitmap: false)
        data = +""
        if null_bitmap
          bitmap_size = (columns.size + 7) / 8
          bitmap = Array.new(bitmap_size, 0)
          columns.each_with_index do |col, index|
            bitmap[index / 8] |= (1 << (index % 8)) if row[col.name].nil?
          end
          data << bitmap.pack("C*")
        end
        columns.each do |col|
          value = row[col.name]
          serialized = serialize(value, col.type_class)
          if variable_length_type?(col.type_class)
            data << [serialized.bytesize].pack("N")
          end
          data << serialized
        end
        data
      end

      def self.variable_length_type?(type)
        !%i[integer bigint smallint float boolean date time timestamp].include?(type.to_sym)
      end

      def self.serialize_header(row_id, column_count)
        [row_id, column_count, Time.now.to_i].pack("Q>I>Q>")
      end

      def self.serialize_metadata(table_name, column_names, column_types)
        {
          table_name: table_name,
          column_names: column_names,
          column_types: column_types,
          created_at: Time.now.iso8601
        }.to_json
      end
    end
  end
end
