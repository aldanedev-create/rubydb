# frozen_string_literal: true

module RubyDB
  module Storage
    # Serializer - Converts Ruby objects to binary format
    class Serializer
      def self.serialize(value, type)
        type_obj = Types::TypeRegistry.lookup(type)
        type_obj.serialize(value)
      end

      def self.serialize_row(row, columns)
        data = ""
        columns.each do |col|
          value = row[col.name]
          serialized = serialize(value, col.type_class)
          data << serialized
        end
        data
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