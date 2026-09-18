# frozen_string_literal: true

module RubyDB
  module Execution
    # Conservative planner estimates. They are deliberately independent from
    # the Go runtime: a wrong estimate must never change SQL semantics.
    class CostModel
      attr_reader :engine

      def initialize(engine)
        @engine = engine
      end

      def apply(plan)
        row_count = table_row_count(plan.table_name)
        selectivity = estimate_selectivity(plan.predicate)
        estimated_rows = [(row_count * selectivity).ceil, 0].max
        cost = case plan.scan_type
        when :index
          plan.predicate ? estimated_rows * 0.1 : row_count * 0.5
        when :sequential
          row_count
        else
          row_count
        end
        cost += sort_cost(estimated_rows) if plan.order_by&.any?
        cost += estimated_rows if plan.aggregates&.any?
        plan.set_cost(cost, estimated_rows)
      end

      def estimate_selectivity(predicate)
        return 1.0 unless predicate

        case predicate
        when Predicate::Comparison
          case predicate.operator
          when :EQ then 0.01
          when :NE then 0.9
          when :LT, :LTE, :GT, :GTE then 0.5
          else 0.5
          end
        when Predicate::And
          estimate_selectivity(predicate.left) * estimate_selectivity(predicate.right)
        when Predicate::Or
          left = estimate_selectivity(predicate.left)
          right = estimate_selectivity(predicate.right)
          left + right - (left * right)
        when Predicate::Not
          1.0 - estimate_selectivity(predicate.operand)
        else
          0.5
        end
      end

      private

      def table_row_count(table_name)
        return 0 unless table_name

        Integer(@engine.table_row_count(table_name))
      rescue
        0
      end

      def sort_cost(rows)
        return 0 if rows < 2

        rows * Math.log2(rows)
      end
    end
  end
end
