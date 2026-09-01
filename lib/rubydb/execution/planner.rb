# frozen_string_literal: true

module RubyDB
  module Execution
    # Planner - Converts AST to execution plan
    class Planner
      attr_reader :engine, :catalog

      def initialize(engine)
        @engine = engine
        @catalog = engine.catalog if engine.respond_to?(:catalog)
        @stats = {
          plans_created: 0,
          optimizations_applied: 0
        }
      end

      def plan(statement)
        @stats[:plans_created] += 1

        plan = case statement
        when SQL::AST::Select
          plan_select(statement)
        when SQL::AST::Insert
          plan_insert(statement)
        when SQL::AST::Update
          plan_update(statement)
        when SQL::AST::Delete
          plan_delete(statement)
        when SQL::AST::CreateTable
          plan_create_table(statement)
        when SQL::AST::DropTable
          plan_drop_table(statement)
        when SQL::AST::CreateIndex
          plan_create_index(statement)
        when SQL::AST::DropIndex
          plan_drop_index(statement)
        when SQL::AST::BeginTransaction
          plan_begin_transaction(statement)
        when SQL::AST::Commit
          plan_commit(statement)
        when SQL::AST::Rollback
          plan_rollback(statement)
        when SQL::AST::Explain
          plan_explain(statement)
        else
          raise ExecutionError, "Unknown statement type: #{statement.class}"
        end

        # Apply optimizations
        plan = optimize(plan)

        plan
      end

      def plan_select(statement)
        table_name = statement.table_name
        columns = statement.columns.map { |col| col.expression.name rescue col.to_s }

        plan = Plan::Select.new(table_name, columns)

        # Handle projections
        if statement.columns.any? && !statement.has_star?
          plan.set_projections(statement.columns)
        end

        # Handle WHERE clause
        if statement.where
          predicate = build_predicate(statement.where)
          plan.set_predicate(predicate)
        end

        # Handle ORDER BY
        if statement.order_by&.any?
          order_by = statement.order_by.map do |order|
            { column: order.expression.name, direction: order.direction }
          end
          plan.set_order_by(order_by)
        end

        # Handle GROUP BY
        if statement.group_by&.any?
          group_by = statement.group_by.map { |g| g.expression.name rescue g.to_s }
          aggregates = statement.columns.select { |c| c.expression.is_a?(SQL::AST::FunctionCall) }
          plan.set_group_by(group_by, aggregates)
        end

        # Handle LIMIT and OFFSET
        if statement.limit
          plan.set_limit(statement.limit.value, statement.offset&.value)
        end

        # Handle DISTINCT
        plan.set_distinct(statement.distinct) if statement.distinct

        # Choose scan method
        choose_scan_method(plan)

        # Estimate cost
        estimate_cost(plan)

        plan
      end

      def plan_insert(statement)
        Plan::Insert.new(
          statement.table,
          statement.columns,
          statement.values
        )
      end

      def plan_update(statement)
        assignments = statement.assignments.map do |ass|
          { column: ass.column, value: ass.value }
        end

        plan = Plan::Update.new(statement.table, assignments)

        if statement.where
          plan.set_predicate(build_predicate(statement.where))
        end

        plan
      end

      def plan_delete(statement)
        plan = Plan::Delete.new(statement.table)

        if statement.where
          plan.set_predicate(build_predicate(statement.where))
        end

        plan
      end

      def plan_create_table(statement)
        columns = statement.columns.map do |col|
          Catalog::Column.new(col.name, col.type_class, col.options)
        end

        Plan::CreateTable.new(statement.name, columns, if_not_exists: statement.if_not_exists)
      end

      def plan_drop_table(statement)
        Plan::DropTable.new(statement.name, if_exists: statement.if_exists)
      end

      def plan_create_index(statement)
        Plan::CreateIndex.new(
          statement.name,
          statement.table_name,
          statement.columns,
          unique: statement.unique,
          if_not_exists: statement.if_not_exists
        )
      end

      def plan_drop_index(statement)
        Plan::DropIndex.new(statement.name, if_exists: statement.if_exists)
      end

      def plan_begin_transaction(statement)
        Plan::BeginTransaction.new(statement.isolation_level)
      end

      def plan_commit(_statement)
        Plan::Commit.new
      end

      def plan_rollback(_statement)
        Plan::Rollback.new
      end

      def plan_explain(statement)
        Plan::Explain.new(statement.statement, statement.analyze)
      end

      # Predicate building
      def build_predicate(ast)
        case ast
        when SQL::AST::BinaryOp
          left = build_predicate(ast.left)
          right = build_predicate(ast.right)

          case ast.operator
          when :AND
            Predicate::And.new(left, right)
          when :OR
            Predicate::Or.new(left, right)
          when :EQ, :NE, :LT, :LTE, :GT, :GTE
            Predicate::Comparison.new(
              build_expression(ast.left),
              build_expression(ast.right),
              ast.operator
            )
          else
            nil
          end
        when SQL::AST::UnaryOp
          operand = build_predicate(ast.operand)
          Predicate::Not.new(operand)
        when SQL::AST::Between
          Predicate::Between.new(
            build_expression(ast.expression),
            build_expression(ast.low),
            build_expression(ast.high)
          )
        when SQL::AST::In
          values = ast.values.map { |v| build_expression(v) }
          Predicate::In.new(build_expression(ast.expression), values)
        when SQL::AST::IsNull
          Predicate::IsNull.new(build_expression(ast.expression), ast.negated)
        when SQL::AST::Like
          Predicate::Like.new(
            build_expression(ast.expression),
            build_expression(ast.pattern),
            ast.case_sensitive
          )
        else
          Predicate::Comparison.new(
            build_expression(ast),
            build_expression(SQL::AST::Literal.new(true, :TRUE)),
            :EQ
          )
        end
      end

      def build_expression(ast)
        case ast
        when SQL::AST::Literal
          Expression::Literal.new(ast.value)
        when SQL::AST::Identifier
          Expression::Column.new(ast.name, ast.table)
        when SQL::AST::BinaryOp
          left = build_expression(ast.left)
          right = build_expression(ast.right)
          Expression::BinaryOp.new(left, right, ast.operator)
        when SQL::AST::UnaryOp
          operand = build_expression(ast.operand)
          Expression::UnaryOp.new(operand, ast.operator)
        when SQL::AST::FunctionCall
          args = ast.arguments.map { |arg| build_expression(arg) }
          Expression::Function.new(ast.name, args)
        when SQL::AST::Parameter
          Expression::Parameter.new(ast.index)
        else
          Expression::Literal.new(nil)
        end
      end

      # Scan method selection
      def choose_scan_method(plan)
        return unless plan.type == :select

        table_name = plan.table_name

        # Check if there's an index that can be used
        if @engine.respond_to?(:index_manager)
          indexes = @engine.index_manager.get_indexes_for_table(table_name)

          # Try to find a matching index for the predicate
          if plan.predicate && indexes.any?
            index = find_matching_index(plan.predicate, indexes)
            if index
              plan.set_scan_type(:index, index)
              return
            end
          end

          # Use first index if no better option
          if indexes.any? && plan.predicate.nil?
            plan.set_scan_type(:index, indexes.first)
            return
          end
        end

        # Default to sequential scan
        plan.set_scan_type(:sequential)
      end

      def find_matching_index(predicate, indexes)
        # Get columns used in predicate
        columns = extract_predicate_columns(predicate)

        indexes.each do |index|
          # Check if predicate columns match index columns
          if index.columns.any? { |col| columns.include?(col) }
            return index
          end
        end

        nil
      end

      def extract_predicate_columns(predicate)
        return [] if predicate.nil?

        case predicate
        when Predicate::Comparison
          left_name = predicate.left.respond_to?(:name) ? predicate.left.name : nil
          [left_name].compact
        when Predicate::And, Predicate::Or
          extract_predicate_columns(predicate.left) + extract_predicate_columns(predicate.right)
        when Predicate::Not
          extract_predicate_columns(predicate.operand)
        when Predicate::Between, Predicate::In, Predicate::IsNull, Predicate::Like
          expr_name = predicate.expression.respond_to?(:name) ? predicate.expression.name : nil
          [expr_name].compact
        else
          []
        end
      end

      # Cost estimation
      def estimate_cost(plan)
        table_name = plan.table_name
        row_count = @engine.table_row_count(table_name) rescue 0

        case plan.scan_type
        when :sequential
          plan.set_cost(row_count, row_count)
        when :index
          # Index scan is cheaper for large tables with selective predicates
          if plan.predicate
            selectivity = estimate_selectivity(plan.predicate)
            estimated_rows = (row_count * selectivity).ceil
            plan.set_cost(estimated_rows * 0.1, estimated_rows)
          else
            plan.set_cost(row_count * 0.5, row_count)
          end
        else
          plan.set_cost(row_count, row_count)
        end
      end

      def estimate_selectivity(predicate)
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
          estimate_selectivity(predicate.left) + estimate_selectivity(predicate.right) -
            estimate_selectivity(predicate.left) * estimate_selectivity(predicate.right)
        when Predicate::Not
          1.0 - estimate_selectivity(predicate.operand)
        else
          0.5
        end
      end

      # Optimization
      def optimize(plan)
        @stats[:optimizations_applied] += 1

        # Push down predicates
        plan = push_down_predicates(plan)

        # Remove redundant conditions
        plan = remove_redundant_conditions(plan)

        # Choose optimal join order (if multiple tables)
        # This is simplified - production would implement join ordering

        plan
      end

      def push_down_predicates(plan)
        # Push predicates down to scan level
        # This is already done in the planner
        plan
      end

      def remove_redundant_conditions(plan)
        if plan.predicate.is_a?(Predicate::And)
          # Simplify AND conditions
          simplified = simplify_and(plan.predicate)
          plan.set_predicate(simplified)
        end
        plan
      end

      def simplify_and(predicate)
        left = predicate.left
        right = predicate.right

        # Remove redundant TRUE conditions
        if left.is_a?(Predicate::Comparison) && left.left.is_a?(Expression::Literal) &&
           left.left.value == true && left.operator == :EQ
          return right
        end

        if right.is_a?(Predicate::Comparison) && right.left.is_a?(Expression::Literal) &&
           right.left.value == true && right.operator == :EQ
          return left
        end

        predicate
      end

      def stats
        @stats
      end
    end
  end
end