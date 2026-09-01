# frozen_string_literal: true

module RubyDB
  module Execution
    # Predicate - Represents conditions in WHERE clause
    class Predicate
      attr_reader :type

      def initialize(type)
        @type = type
      end

      def evaluate(row)
        raise NotImplementedError
      end

      def to_s
        raise NotImplementedError
      end

      def negate
        Predicate::Not.new(self)
      end

      # Comparison predicate: column = value
      class Comparison < Predicate
        attr_reader :left, :right, :operator

        def initialize(left, right, operator)
          super(:comparison)
          @left = left
          @right = right
          @operator = operator
        end

        def evaluate(row)
          left_val = @left.evaluate(row)
          right_val = @right.evaluate(row)

          return false if left_val.nil? || right_val.nil?

          case @operator
          when :eq then left_val == right_val
          when :ne then left_val != right_val
          when :lt then left_val < right_val
          when :lte then left_val <= right_val
          when :gt then left_val > right_val
          when :gte then left_val >= right_val
          when :like then like_match?(left_val.to_s, right_val.to_s)
          else false
          end
        end

        def to_s
          op = case @operator
          when :eq then "="
          when :ne then "!="
          when :lt then "<"
          when :lte then "<="
          when :gt then ">"
          when :gte then ">="
          when :like then "LIKE"
          else @operator.to_s
          end
          "#{@left} #{op} #{@right}"
        end

        private

        def like_match?(value, pattern)
          regex_str = Regexp.escape(pattern)
            .gsub('%', '.*')
            .gsub('_', '.')
          Regexp.new("^#{regex_str}$", Regexp::IGNORECASE).match?(value)
        end
      end

      # AND predicate
      class And < Predicate
        attr_reader :left, :right

        def initialize(left, right)
          super(:and)
          @left = left
          @right = right
        end

        def evaluate(row)
          @left.evaluate(row) && @right.evaluate(row)
        end

        def to_s
          "(#{@left}) AND (#{@right})"
        end
      end

      # OR predicate
      class Or < Predicate
        attr_reader :left, :right

        def initialize(left, right)
          super(:or)
          @left = left
          @right = right
        end

        def evaluate(row)
          @left.evaluate(row) || @right.evaluate(row)
        end

        def to_s
          "(#{@left}) OR (#{@right})"
        end
      end

      # NOT predicate
      class Not < Predicate
        attr_reader :operand

        def initialize(operand)
          super(:not)
          @operand = operand
        end

        def evaluate(row)
          !@operand.evaluate(row)
        end

        def to_s
          "NOT (#{@operand})"
        end
      end

      # BETWEEN predicate
      class Between < Predicate
        attr_reader :expression, :low, :high

        def initialize(expression, low, high)
          super(:between)
          @expression = expression
          @low = low
          @high = high
        end

        def evaluate(row)
          val = @expression.evaluate(row)
          low_val = @low.evaluate(row)
          high_val = @high.evaluate(row)

          return false if val.nil? || low_val.nil? || high_val.nil?

          val >= low_val && val <= high_val
        end

        def to_s
          "#{@expression} BETWEEN #{@low} AND #{@high}"
        end
      end

      # IN predicate
      class In < Predicate
        attr_reader :expression, :values

        def initialize(expression, values)
          super(:in)
          @expression = expression
          @values = values
        end

        def evaluate(row)
          val = @expression.evaluate(row)
          return false if val.nil?

          @values.any? { |v| v.evaluate(row) == val }
        end

        def to_s
          values = @values.map(&:to_s).join(", ")
          "#{@expression} IN (#{values})"
        end
      end

      # IS NULL predicate
      class IsNull < Predicate
        attr_reader :expression, :negated

        def initialize(expression, negated = false)
          super(:is_null)
          @expression = expression
          @negated = negated
        end

        def evaluate(row)
          val = @expression.evaluate(row)
          @negated ? !val.nil? : val.nil?
        end

        def to_s
          @negated ? "#{@expression} IS NOT NULL" : "#{@expression} IS NULL"
        end
      end

      # LIKE predicate
      class Like < Predicate
        attr_reader :expression, :pattern, :case_sensitive

        def initialize(expression, pattern, case_sensitive = true)
          super(:like)
          @expression = expression
          @pattern = pattern
          @case_sensitive = case_sensitive
        end

        def evaluate(row)
          val = @expression.evaluate(row)
          pat = @pattern.evaluate(row)

          return false if val.nil? || pat.nil?

          str = @case_sensitive ? val.to_s : val.to_s.downcase
          pat_str = @case_sensitive ? pat.to_s : pat.to_s.downcase

          regex_str = Regexp.escape(pat_str)
            .gsub('%', '.*')
            .gsub('_', '.')
          Regexp.new("^#{regex_str}$").match?(str)
        end

        def to_s
          @case_sensitive ? "#{@expression} LIKE #{@pattern}" : "#{@expression} ILIKE #{@pattern}"
        end
      end
    end
  end
end