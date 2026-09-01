# frozen_string_literal: true

module RubyDB
  module Execution
    # Expression - Represent values, columns, and operations
    class Expression
      attr_reader :type, :value, :name, :left, :right, :operator,
                  :operand, :alias, :arguments

      def initialize(type, **attrs)
        @type = type
        @value = attrs[:value]
        @name = attrs[:name]
        @left = attrs[:left]
        @right = attrs[:right]
        @operator = attrs[:operator]
        @operand = attrs[:operand]
        @alias = attrs[:alias]
        @arguments = attrs[:arguments] || []
      end

      def to_s
        case @type
        when :literal
          @value.to_s
        when :column
          @name.to_s
        when :binary_op
          "#{@left} #{@operator} #{@right}"
        when :unary_op
          "#{@operator} #{@operand}"
        when :function
          "#{@name}(#{@arguments.map(&:to_s).join(', ')})"
        when :parameter
          "?"
        else
          "?"
        end
      end

      # Literal value
      class Literal < Expression
        def initialize(value)
          super(:literal, value: value)
        end

        def evaluate(_row = nil)
          @value
        end

        def to_s
          if @value.nil?
            "NULL"
          elsif @value.is_a?(String)
            "'#{@value}'"
          else
            @value.to_s
          end
        end
      end

      # Column reference
      class Column < Expression
        attr_reader :table

        def initialize(name, table = nil)
          super(:column, name: name)
          @table = table
        end

        def evaluate(row)
          return nil unless row
          row[@name] || row[@name.to_sym]
        end

        def to_s
          @table ? "#{@table}.#{@name}" : @name.to_s
        end
      end

      # Binary operation
      class BinaryOp < Expression
        def initialize(left, right, operator)
          super(:binary_op, left: left, right: right, operator: operator)
        end

        def evaluate(row)
          left_val = @left.evaluate(row)
          right_val = @right.evaluate(row)

          return nil if left_val.nil? || right_val.nil?

          case @operator
          when :plus then left_val + right_val
          when :minus then left_val - right_val
          when :multiply then left_val * right_val
          when :divide then right_val != 0 ? left_val / right_val : nil
          when :modulo then right_val != 0 ? left_val % right_val : nil
          when :concat then left_val.to_s + right_val.to_s
          when :eq then left_val == right_val
          when :ne then left_val != right_val
          when :lt then left_val < right_val
          when :lte then left_val <= right_val
          when :gt then left_val > right_val
          when :gte then left_val >= right_val
          else nil
          end
        end

        def to_s
          "#{@left} #{@operator} #{@right}"
        end
      end

      # Unary operation
      class UnaryOp < Expression
        def initialize(operand, operator)
          super(:unary_op, operand: operand, operator: operator)
        end

        def evaluate(row)
          val = @operand.evaluate(row)
          return nil if val.nil?

          case @operator
          when :negate then -val
          when :not then !val
          else val
          end
        end

        def to_s
          "#{@operator} #{@operand}"
        end
      end

      # Function call
      class Function < Expression
        def initialize(name, arguments = [], alias_name = nil)
          super(:function, name: name, arguments: arguments, alias: alias_name)
        end

        def evaluate(row)
          args = @arguments.map { |arg| arg.evaluate(row) }

          case @name.to_s.upcase
          when "COUNT" then args.compact.size
          when "SUM" then args.compact.sum
          when "AVG"
            vals = args.compact
            vals.empty? ? 0 : vals.sum / vals.size.to_f
          when "MIN" then args.compact.min
          when "MAX" then args.compact.max
          when "LOWER" then args.first.to_s.downcase
          when "UPPER" then args.first.to_s.upcase
          when "LENGTH" then args.first.to_s.length
          when "COALESCE" then args.find { |arg| !arg.nil? }
          when "NOW" then Time.now
          when "CURRENT_DATE" then Date.today
          when "CURRENT_TIME" then Time.now
          else nil
          end
        end

        def to_s
          args = @arguments.map(&:to_s).join(", ")
          "#{@name}(#{args})"
        end
      end

      # Parameter placeholder
      class Parameter < Expression
        attr_reader :index

        def initialize(index = nil)
          super(:parameter, value: index)
          @index = index
        end

        def evaluate(_row = nil)
          @value
        end

        def to_s
          @index ? "$#{@index}" : "?"
        end
      end
    end
  end
end