# frozen_string_literal: true

module RubyDB
  module Rails
    # Type - Maps Ruby/Rails types to RubyDB types
    class Type
      TYPE_MAPPING = {
        integer: :integer,
        bigint: :bigint,
        smallint: :smallint,
        float: :float,
        decimal: :decimal,
        boolean: :boolean,
        text: :text,
        string: :varchar,
        blob: :blob,
        date: :date,
        time: :time,
        datetime: :timestamp,
        timestamp: :timestamp,
        json: :json,
        uuid: :uuid,
        primary_key: :integer,
        references: :integer
      }

      RUBYDB_TO_RAILS = {
        integer: :integer,
        bigint: :bigint,
        smallint: :smallint,
        float: :float,
        decimal: :decimal,
        boolean: :boolean,
        text: :text,
        varchar: :string,
        char: :string,
        blob: :binary,
        date: :date,
        time: :time,
        timestamp: :datetime,
        json: :json,
        uuid: :uuid,
        null: :null
      }

      def self.to_rubydb(rails_type, options = {})
        type = TYPE_MAPPING[rails_type.to_sym]
        return type if type

        # Handle special cases
        case rails_type.to_s
        when "primary_key"
          :integer
        when "references"
          :integer
        when "jsonb"
          :json
        when "binary"
          :blob
        when "datetime"
          :timestamp
        when "timestamp"
          :timestamp
        else
          :text
        end
      end

      def self.to_rails(rubydb_type)
        RUBYDB_TO_RAILS[rubydb_type.to_sym] || :string
      end

      def self.native_database_types
        {
          primary_key: "INTEGER PRIMARY KEY AUTOINCREMENT",
          string: { name: "VARCHAR", limit: 255 },
          text: { name: "TEXT" },
          integer: { name: "INTEGER" },
          bigint: { name: "BIGINT" },
          float: { name: "FLOAT" },
          decimal: { name: "DECIMAL", precision: 10, scale: 2 },
          datetime: { name: "TIMESTAMP" },
          timestamp: { name: "TIMESTAMP" },
          time: { name: "TIME" },
          date: { name: "DATE" },
          binary: { name: "BLOB" },
          boolean: { name: "BOOLEAN" },
          json: { name: "JSON" },
          uuid: { name: "UUID" }
        }
      end

      def self.serialize(value, type)
        case type.to_sym
        when :integer, :bigint, :smallint
          value.to_i if value
        when :float, :decimal
          value.to_f if value
        when :boolean
          !!value
        when :json
          value.is_a?(String) ? JSON.parse(value) : value
        when :timestamp, :datetime
          value.is_a?(String) ? Time.parse(value) : value
        when :date
          value.is_a?(String) ? Date.parse(value) : value
        else
          value
        end
      end

      def self.deserialize(value, type)
        case type.to_sym
        when :json
          value.is_a?(Hash) ? value.to_json : value
        when :timestamp, :datetime
          value.is_a?(Time) ? value.iso8601 : value
        when :date
          value.is_a?(Date) ? value.iso8601 : value
        else
          value
        end
      end
    end
  end
end