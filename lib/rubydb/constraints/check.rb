# frozen_string_literal: true

module RubyDB
  module Constraints
    # CheckConstraint - Ensures row satisfies a condition
    class CheckConstraint < Constraint
      attr_reader :expression

      def initialize(table_name, expression, options = {})
        super(
          options[:name] || "chk_#{table_name}_#{Time.now.to_i}",
          TYPE_CHECK,
          table_name,
          options
        )
        @expression = expression
        @expression_type = options[:expression_type] || :sql
        @validated = false
      end

      def validate(row)
        return true unless enabled?

        result = evaluate_expression(row)
        if result == false
          @validation_errors << "Check constraint failed: #{@expression}"
          return false
        end

        true
      end

      def validate_batch(rows)
        results = { valid: [], invalid: [] }

        rows.each do |row|
          if validate(row)
            results[:valid] << row
          else
            results[:invalid] << row
          end
        end

        results
      end

      def evaluate_expression(row)
        case @expression_type
        when :ruby
          # Evaluate Ruby expression
          eval_expression(@expression, row)
        when :lambda
          # Call lambda with row
          @expression.call(row)
        else
          # Evaluate SQL expression - simplified
          eval_sql_expression(@expression, row)
        end
      rescue => e
        @validation_errors << "Expression evaluation error: #{e.message}"
        false
      end

      def eval_expression(expr, row)
        case expr
        when Symbol, String
          evaluate_predicate(expr.to_s.strip, row)
        when Proc
          expr.call(row)
        else
          true
        end
      end

      def eval_sql_expression(expr, row)
        evaluate_predicate(expr.to_s.strip, row)
      end

      def evaluate_predicate(expression, row)
        expression = strip_outer_parentheses(expression.strip)

        split_top_level(expression, "OR").any? do |part|
          split_top_level(part, "AND").all? { |term| evaluate_term(term, row) }
        end
      end

      def evaluate_term(term, row)
        term = strip_outer_parentheses(term.strip)
        if term =~ /\A([\w.]+)\s+IS\s+(NOT\s+)?NULL\z/i
          value = row_value(row, Regexp.last_match(1))
          return Regexp.last_match(2).nil? ? value.nil? : !value.nil?
        end

        match = term.match(/\A([\w.]+)\s*(>=|<=|<>|!=|=|>|<)\s*(.+)\z/i)
        return false unless match

        compare_value(row_value(row, match[1]), match[3].strip, match[2])
      end

      def row_value(row, column)
        key = column.to_s.split(".").last
        row.key?(key) ? row[key] : row[key.to_sym]
      end

      def strip_outer_parentheses(expression)
        while expression.start_with?("(") && expression.end_with?( ")") && balanced_parentheses?(expression[1...-1])
          expression = expression[1...-1].strip
        end
        expression
      end

      def balanced_parentheses?(expression)
        depth = 0
        expression.each_char do |char|
          depth += 1 if char == "("
          depth -= 1 if char == ")"
          return false if depth.negative?
        end
        depth.zero?
      end

      def split_top_level(expression, operator)
        parts = []
        depth = 0
        start = 0
        expression.to_enum(:scan, /\(|\)|\b#{operator}\b/i).each do
          match = Regexp.last_match
          token = match[0]
          if token == "("
            depth += 1
          elsif token == ")"
            depth -= 1
          elsif depth.zero?
            parts << expression[start...match.begin(0)].strip
            start = match.end(0)
          end
        end
        parts << expression[start..].strip
        parts.size > 1 ? parts : [expression]
      end

      def compare_value(row_val, val, op)
        # Parse the value
        parsed_val = case val
        when /^'(.+)'$/ then $1
        when /^\d+$/ then val.to_i
        when /^\d+\.\d+$/ then val.to_f
        when /^true$/i then true
        when /^false$/i then false
        when /^null$/i then nil
        else val
        end

        case op
        when "=" then row_val == parsed_val
        when "!=", "<>" then row_val != parsed_val
        when ">" then row_val > parsed_val
        when ">=" then row_val >= parsed_val
        when "<" then row_val < parsed_val
        when "<=" then row_val <= parsed_val
        else false
        end
      end

      def to_sql
        "CHECK (#{@expression})"
      end

      def to_hash
        super.merge({
          expression: @expression,
          expression_type: @expression_type
        })
      end

      def inspect
        "#<CheckConstraint name=#{@name} expression=#{@expression}>"
      end
    end
  end
end
