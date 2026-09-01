# frozen_string_literal: true

module RubyDB
  module Rails
    # Quoting - Handles SQL quoting
    module Quoting
      QUOTE_CHARACTER = "'"
      ESCAPE_CHARACTER = "\\"
      IDENTIFIER_QUOTE = "\""

      def quote(value, column = nil)
        return "NULL" if value.nil?

        case value
        when String
          quote_string(value)
        when Numeric
          value.to_s
        when TrueClass
          "TRUE"
        when FalseClass
          "FALSE"
        when Date, Time, DateTime
          quote_string(value.iso8601)
        when Symbol
          quote_string(value.to_s)
        when Array
          value.map { |v| quote(v) }.join(", ")
        else
          quote_string(value.to_s)
        end
      end

      def quote_string(string)
        "'#{string.gsub("'", "''")}'"
      end

      def quote_table_name(name)
        "\"#{name.to_s}\""
      end

      def quote_column_name(name)
        "\"#{name.to_s}\""
      end

      def quote_table_name_if_needed(name)
        name = name.to_s
        return name if name.start_with?("\"") && name.end_with?("\"")
        quote_table_name(name)
      end

      def quote_column_name_if_needed(name)
        name = name.to_s
        return name if name.start_with?("\"") && name.end_with?("\"")
        quote_column_name(name)
      end

      def quote_identifier(name)
        name = name.to_s
        return name if name =~ /^[a-zA-Z_][a-zA-Z0-9_]*$/
        "\"#{name.gsub('"', '""')}\""
      end

      def quote_default(value)
        case value
        when nil
          "NULL"
        when String
          quote_string(value)
        when Numeric
          value.to_s
        when TrueClass
          "TRUE"
        when FalseClass
          "FALSE"
        when Date, Time, DateTime
          quote_string(value.iso8601)
        else
          quote_string(value.to_s)
        end
      end

      def unquote(string)
        return nil if string.nil? || string == "NULL"
        return string[1..-2] if string.start_with?("'") && string.end_with?("'")
        string
      end

      private

      def quote_bound_value(value)
        case value
        when String
          quote_string(value)
        when Numeric
          value
        when TrueClass
          1
        when FalseClass
          0
        when Date, Time, DateTime
          quote_string(value.iso8601)
        else
          quote_string(value.to_s)
        end
      end
    end
  end
end