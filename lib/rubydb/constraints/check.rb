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
        # Simple expression evaluator for Ruby expressions
        # Supports basic comparisons and logic
        case expr
        when Symbol, String
          expr = expr.to_s
          # Parse simple conditions like "age > 18"
          if expr =~ /(\w+)\s*(>=|<=|>|<|=|!=)\s*(.+)/
            col = $1.strip
            op = $2.strip
            val = $3.strip

            row_val = row[col]
            return false if row_val.nil?

            compare_value(row_val, val, op)
          else
            true
          end
        when Proc
          expr.call(row)
        else
          true
        end
      end

      def eval_sql_expression(expr, row)
        # Simplified SQL expression evaluation
        # In production, this would use the SQL parser
        true
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
        when "!=" then row_val != parsed_val
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