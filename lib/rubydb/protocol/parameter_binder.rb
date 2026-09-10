# frozen_string_literal: true

require "date"

module RubyDB
  module Protocol
    # Converts protocol parameters into SQL literals before the SQL parser.
    # RubyDB's wire protocol transports values separately, while the current
    # parser accepts literal expressions. Keeping this conversion here makes
    # every network client use the same escaping and placeholder rules.
    module ParameterBinder
      module_function

      def bind(sql, params)
        params = Array(params)
        return sql if params.empty?

        result = +""
        index = 0
        used_indices = []
        position = 0
        single_quoted = false
        double_quoted = false

        while position < sql.length
          char = sql[position]

          if char == "'" && !double_quoted
            if single_quoted && sql[position + 1] == "'"
              result << "''"
              position += 2
              next
            end
            single_quoted = !single_quoted
            result << char
          elsif char == '"' && !single_quoted
            if double_quoted && sql[position + 1] == '"'
              result << '""'
              position += 2
              next
            end
            double_quoted = !double_quoted
            result << char
          elsif char == "?" && !single_quoted && !double_quoted
            raise ArgumentError, "Not enough bind parameters" if index >= params.size

            result << quote(params[index])
            used_indices << index
            index += 1
          elsif char == "$" && !single_quoted && !double_quoted
            placeholder = sql[position..].match(/\A\$(\d+)/)
            if placeholder
              parameter_index = placeholder[1].to_i - 1
              if parameter_index.negative? || parameter_index >= params.size
                raise ArgumentError, "Bind parameter #{parameter_index + 1} is out of range"
              end

              result << quote(params[parameter_index])
              used_indices << parameter_index
              position += placeholder[0].length - 1
            else
              result << char
            end
          else
            result << char
          end
          position += 1
        end

        if used_indices.uniq.size != params.size
          raise ArgumentError, "Too many bind parameters"
        end

        result
      end

      def quote(value)
        case value
        when nil
          "NULL"
        when String
          "'#{value.gsub("'", "''")}'"
        when Numeric
          value.to_s
        when TrueClass
          "TRUE"
        when FalseClass
          "FALSE"
        when Date, Time, DateTime
          "'#{value.iso8601.gsub("'", "''")}'"
        when Symbol
          "'#{value.to_s.gsub("'", "''")}'"
        when Array
          value.map { |item| quote(item) }.join(", ")
        else
          "'#{value.to_s.gsub("'", "''")}'"
        end
      end
    end
  end
end
