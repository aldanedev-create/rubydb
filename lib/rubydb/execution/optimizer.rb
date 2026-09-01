# frozen_string_literal: true

module RubyDB
  module Execution
    # Optimizer - Query optimization with cost-based decisions
    class Optimizer
      attr_reader :stats

      def initialize(engine)
        @engine = engine
        @stats = {
          optimizations: 0,
          plans_considered: 0,
          best_plan_found: 0
        }
        @lock = Mutex.new
      end

      def optimize(plan)
        @lock.synchronize do
          @stats[:plans_considered] += 1

          # Generate alternative plans
          alternatives = generate_alternatives(plan)

          # Choose the best plan
          best_plan = choose_best_plan(alternatives)

          @stats[:best_plan_found] += 1
          @stats[:optimizations] += 1

          best_plan
        end
      end

      def generate_alternatives(plan)
        alternatives = [plan]

        # If SELECT, try different scan methods
        if plan.is_a?(Plan::Select)
          # Try sequential scan
          seq_plan = plan.dup
          seq_plan.set_scan_type(:sequential)
          alternatives << seq_plan

          # Try index scan if available
          if @engine.respond_to?(:index_manager)
            indexes = @engine.index_manager.get_indexes_for_table(plan.table_name)
            indexes.each do |index|
              idx_plan = plan.dup
              idx_plan.set_scan_type(:index, index)
              alternatives << idx_plan
            end
          end

          # Try different join orders if multiple tables
          # This is simplified - production would implement join ordering
        end

        alternatives
      end

      def choose_best_plan(plans)
        return plans.first if plans.size == 1

        best_plan = nil
        best_cost = Float::INFINITY

        plans.each do |plan|
          cost = calculate_cost(plan)
          if cost < best_cost
            best_cost = cost
            best_plan = plan
          end
        end

        best_plan || plans.first
      end

      def calculate_cost(plan)
        case plan
        when Plan::Select
          calculate_select_cost(plan)
        when Plan::Insert
          1.0
        when Plan::Update
          calculate_update_cost(plan)
        when Plan::Delete
          calculate_delete_cost(plan)
        else
          1.0
        end
      end

      def calculate_select_cost(plan)
        table_name = plan.table_name
        row_count = @engine.table_row_count(table_name) rescue 1000

        base_cost = case plan.scan_type
        when :sequential
          row_count
        when :index
          row_count * 0.1
        else
          row_count
        end

        # Add predicate cost
        if plan.predicate
          selectivity = estimate_selectivity(plan.predicate)
          base_cost *= selectivity
        end

        # Add order by cost
        if plan.order_by && plan.order_by.any?
          base_cost += row_count * Math.log2(row_count)
        end

        # Add group by cost
        if plan.group_by && plan.group_by.any?
          base_cost += row_count * 1.5
        end

        # Add limit/offset cost
        if plan.limit
          base_cost *= 0.5
        end

        base_cost
      end

      def calculate_update_cost(plan)
        table_name = plan.table_name
        row_count = @engine.table_row_count(table_name) rescue 1000

        cost = row_count

        if plan.predicate
          selectivity = estimate_selectivity(plan.predicate)
          cost *= selectivity
        end

        cost
      end

      def calculate_delete_cost(plan)
        table_name = plan.table_name
        row_count = @engine.table_row_count(table_name) rescue 1000

        cost = row_count

        if plan.predicate
          selectivity = estimate_selectivity(plan.predicate)
          cost *= selectivity
        end

        cost
      end

      def estimate_selectivity(predicate)
        case predicate
        when Predicate::Comparison
          case predicate.operator
          when :EQ then 0.01
          when :NE then 0.9
          when :LT, :LTE, :GT, :GTE then 0.5
          when :LIKE then 0.1
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
        when Predicate::Between
          0.3
        when Predicate::In
          0.02 * predicate.values.size
        else
          0.5
        end
      end

      def analyze_plan(plan)
        {
          plan_type: plan.type,
          table: plan.table_name,
          scan_type: plan.scan_type,
          has_predicate: !plan.predicate.nil?,
          has_order_by: plan.order_by && plan.order_by.any?,
          has_group_by: plan.group_by && plan.group_by.any?,
          has_limit: !plan.limit.nil?,
          estimated_cost: calculate_cost(plan)
        }
      end

      def explain_optimization(plan)
        before = calculate_cost(plan)
        optimized = optimize(plan)
        after = calculate_cost(optimized)

        {
          original_cost: before,
          optimized_cost: after,
          improvement: ((before - after) / before * 100).round(2),
          optimized_plan: optimized
        }
      end
    end
  end
end