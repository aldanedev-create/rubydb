# frozen_string_literal: true

require "set"

module RubyDB
  module Execution
    # Executor - Executes query plans and returns results
    class Executor
      attr_reader :engine, :stats

      def initialize(engine)
        @engine = engine
        @stats = {
          queries_executed: 0,
          rows_returned: 0,
          total_time_ms: 0,
          sequential_scans: 0,
          index_scans: 0,
          joins: 0,
          aggregations: 0,
          sorts: 0
        }
        @lock = Mutex.new
        @current_transaction = nil
        @explain_mode = false
      end

      def execute(plan, transaction_id = nil)
        @lock.synchronize do
          start_time = Time.now
          @stats[:queries_executed] += 1
          @current_transaction = transaction_id

          result = case plan
          when Plan::Select
            execute_select(plan)
          when Plan::Insert
            execute_insert(plan)
          when Plan::Update
            execute_update(plan)
          when Plan::Delete
            execute_delete(plan)
          when Plan::CreateTable
            execute_create_table(plan)
          when Plan::DropTable
            execute_drop_table(plan)
          when Plan::CreateDatabase
            execute_create_database(plan)
          when Plan::DropDatabase
            execute_drop_database(plan)
          when Plan::CreateSchema
            execute_create_schema(plan)
          when Plan::DropSchema
            execute_drop_schema(plan)
          when Plan::CreateView
            execute_create_view(plan)
          when Plan::DropView
            execute_drop_view(plan)
          when Plan::CreateTrigger
            execute_create_trigger(plan)
          when Plan::DropTrigger
            execute_drop_trigger(plan)
          when Plan::Vacuum
            execute_vacuum(plan)
          when Plan::AlterTableAddColumn
            execute_alter_table_add_column(plan)
          when Plan::AlterTableDropColumn
            execute_alter_table_drop_column(plan)
          when Plan::AlterTableAddConstraint
            execute_alter_table_add_constraint(plan)
          when Plan::AlterTableDropConstraint
            execute_alter_table_drop_constraint(plan)
          when Plan::CreateIndex
            execute_create_index(plan)
          when Plan::DropIndex
            execute_drop_index(plan)
          when Plan::BeginTransaction
            execute_begin_transaction(plan)
          when Plan::Commit
            execute_commit(plan)
          when Plan::Rollback
            execute_rollback(plan)
          when Plan::Savepoint
            execute_savepoint(plan)
          when Plan::RollbackToSavepoint
            execute_rollback_to_savepoint(plan)
          when Plan::ReleaseSavepoint
            execute_release_savepoint(plan)
          when Plan::Explain
            execute_explain(plan)
          else
            raise ExecutionError, "Unknown plan type: #{plan.class}"
          end

          elapsed_ms = ((Time.now - start_time) * 1000).round(2)
          @stats[:total_time_ms] += elapsed_ms
          @stats[:rows_returned] += result[:row_count] if result && result[:row_count]

          result
        end
      end

      def execute_select(plan)
        @stats[:sequential_scans] += 1 if plan.scan_type == :sequential
        @stats[:index_scans] += 1 if plan.scan_type == :index

        # Get the table data
        rows = scan_table(plan)

        # Apply filters (WHERE clause)
        if plan.predicate
          rows = rows.select { |row| evaluate_predicate(plan.predicate, row) }
        end

        # ORDER BY is evaluated against the source rows, so a column used
        # solely for ordering remains available even when it is not selected.
        if plan.order_by && !plan.order_by.empty? && (!plan.group_by || plan.group_by.empty?)
          rows = sort_rows(rows, plan.order_by)
        end

        # Apply projections (SELECT columns)
        if plan.projections
          rows = rows.map { |row| project_row(row, plan.projections) }
        end

        # Apply DISTINCT
        if plan.distinct
          rows = distinct_rows(rows)
        end

        # Apply GROUP BY
        if plan.group_by && !plan.group_by.empty?
          rows = group_rows(rows, plan.group_by, plan.aggregates)
        end

        # Apply ORDER BY
        if plan.order_by && !plan.order_by.empty? && plan.group_by && !plan.group_by.empty?
          rows = sort_rows(rows, plan.order_by)
        end

        # Apply LIMIT and OFFSET
        if plan.limit
          offset = plan.offset || 0
          rows = rows[offset, plan.limit] || []
        elsif plan.offset
          rows = rows[plan.offset..-1] || []
        end

        {
          rows: rows,
          row_count: rows.size,
          column_names: get_column_names(plan)
        }
      end

      def execute_insert(plan)
        table_name = plan.table_name
        columns = plan.columns
        values = plan.values

        # Build row data
        row_data = {}
        columns.each_with_index do |col, idx|
          row_data[col] = evaluate_expression(values[idx])
        end

        # Insert into engine
        table_columns = @engine.table_columns(table_name)
        row_id = @engine.insert_row(table_name, table_columns, row_data)

        {
          row_count: 1,
          affected_rows: 1,
          row_id: row_id,
          message: "INSERT 1"
        }
      end

      def execute_update(plan)
        table_name = plan.table_name
        assignments = plan.assignments
        predicate = plan.predicate

        # Get rows to update
        rows = scan_table(Plan::Select.new(table_name, []))
        rows = rows.select { |row| evaluate_predicate(predicate, row) } if predicate

        updated_count = 0
        rows.each do |row|
          # Apply updates
          assignments.each do |assignment|
            row[assignment.column] = evaluate_expression(assignment.value, row)
          end

          # Update in engine
          row_id = row[:_row_id] || row["_row_id"] || row[:id] || row["id"]
          @engine.update_row(table_name, row_id, row)

          updated_count += 1
        end

        {
          row_count: updated_count,
          affected_rows: updated_count,
          message: "UPDATE #{updated_count}"
        }
      end

      def execute_delete(plan)
        table_name = plan.table_name
        predicate = plan.predicate

        # Get rows to delete
        rows = scan_table(Plan::Select.new(table_name, []))
        rows = rows.select { |row| evaluate_predicate(predicate, row) } if predicate

        deleted_count = 0
        rows.each do |row|
          row_id = row[:_row_id] || row["_row_id"] || row[:id] || row["id"]
          @engine.delete_row(table_name, row_id)
          deleted_count += 1
        end

        {
          row_count: deleted_count,
          affected_rows: deleted_count,
          message: "DELETE #{deleted_count}"
        }
      end

      def execute_create_table(plan)
        table_name = plan.table_name
        columns = plan.columns
        options = plan.options || {}

        @engine.create_table(table_name, columns, options)

        {
          row_count: 0,
          message: "CREATE TABLE #{table_name}"
        }
      end

      def execute_drop_table(plan)
        table_name = plan.table_name
        options = plan.options || {}

        @engine.drop_table(table_name, options)

        {
          row_count: 0,
          message: "DROP TABLE #{table_name}"
        }
      end

      def execute_create_database(plan)
        @engine.catalog.create_database(plan.database_name, **(plan.options || {}))
        { row_count: 0, message: "CREATE DATABASE #{plan.database_name}" }
      end

      def execute_drop_database(plan)
        @engine.catalog.drop_database(plan.database_name, **(plan.options || {}))
        { row_count: 0, message: "DROP DATABASE #{plan.database_name}" }
      end

      def execute_create_schema(plan)
        @engine.catalog.create_schema(plan.schema_name, **(plan.options || {}))
        { row_count: 0, message: "CREATE SCHEMA #{plan.schema_name}" }
      end

      def execute_drop_schema(plan)
        @engine.catalog.drop_schema(plan.schema_name, **(plan.options || {}))
        { row_count: 0, message: "DROP SCHEMA #{plan.schema_name}" }
      end

      def execute_create_view(plan)
        query = plan.query.respond_to?(:to_sql) ? plan.query.to_sql : plan.query
        @engine.catalog.create_view(plan.view_name, query, **(plan.options || {}))
        { row_count: 0, message: "CREATE VIEW #{plan.view_name}" }
      end

      def execute_drop_view(plan)
        @engine.catalog.drop_view(plan.view_name, **(plan.options || {}))
        { row_count: 0, message: "DROP VIEW #{plan.view_name}" }
      end

      def execute_create_trigger(plan)
        definition = "EXECUTE FUNCTION #{plan.function_name}()"
        @engine.catalog.create_trigger(plan.trigger_name, plan.event, plan.target_table, definition, timing: plan.timing, function_name: plan.function_name)
        { row_count: 0, message: "CREATE TRIGGER #{plan.trigger_name}" }
      end

      def execute_drop_trigger(plan)
        @engine.catalog.drop_trigger(plan.trigger_name, **(plan.options || {}))
        { row_count: 0, message: "DROP TRIGGER #{plan.trigger_name}" }
      end

      def execute_vacuum(_plan)
        result = @engine.vacuum
        { row_count: 0, vacuum: result, message: "VACUUM" }
      end

      def execute_alter_table_add_column(plan)
        @engine.add_column(plan.table_name, plan.column_name, plan.column_type, plan.options)
        { row_count: 0, message: "ALTER TABLE #{plan.table_name} ADD COLUMN #{plan.column_name}" }
      end

      def execute_alter_table_drop_column(plan)
        @engine.drop_column(plan.table_name, plan.column_name)
        { row_count: 0, message: "ALTER TABLE #{plan.table_name} DROP COLUMN #{plan.column_name}" }
      end

      def execute_alter_table_add_constraint(plan)
        @engine.add_constraint(plan.table_name, plan.constraint)
        { row_count: 0, message: "ALTER TABLE #{plan.table_name} ADD CONSTRAINT #{plan.constraint.name}" }
      end

      def execute_alter_table_drop_constraint(plan)
        @engine.drop_constraint(plan.table_name, plan.constraint_name)
        { row_count: 0, message: "ALTER TABLE #{plan.table_name} DROP CONSTRAINT #{plan.constraint_name}" }
      end

      def execute_create_index(plan)
        index_name = plan.index_name
        table_name = plan.table_name
        columns = plan.columns
        options = plan.options || {}

        if @engine.respond_to?(:index_manager)
          @engine.index_manager.create_index(index_name, table_name, columns, options)
        end

        {
          row_count: 0,
          message: "CREATE INDEX #{index_name}"
        }
      end

      def execute_drop_index(plan)
        index_name = plan.index_name
        options = plan.options || {}

        if @engine.respond_to?(:index_manager)
          @engine.index_manager.drop_index(index_name, options)
        end

        {
          row_count: 0,
          message: "DROP INDEX #{index_name}"
        }
      end

      def execute_begin_transaction(plan)
        isolation_level = plan.isolation_level || :read_committed
        transaction_id = @engine.begin_transaction(isolation_level)

        {
          row_count: 0,
          transaction_id: transaction_id,
          message: "BEGIN"
        }
      end

      def execute_commit(plan)
        @engine.commit_transaction

        {
          row_count: 0,
          message: "COMMIT"
        }
      end

      def execute_rollback(plan)
        @engine.rollback_transaction

        {
          row_count: 0,
          message: "ROLLBACK"
        }
      end

      def execute_savepoint(plan)
        @engine.create_savepoint(plan.name)
        { row_count: 0, message: "SAVEPOINT #{plan.name}" }
      end

      def execute_rollback_to_savepoint(plan)
        @engine.rollback_to_savepoint(plan.name)
        { row_count: 0, message: "ROLLBACK TO SAVEPOINT #{plan.name}" }
      end

      def execute_release_savepoint(plan)
        @engine.release_savepoint(plan.name)
        { row_count: 0, message: "RELEASE SAVEPOINT #{plan.name}" }
      end

      def execute_explain(plan)
        statement = plan.statement
        analyze = plan.analyze || false

        # Generate execution plan for the statement
        planner = Planner.new(@engine)
        analyzed_plan = planner.plan(statement)

        # Format the plan
        plan_text = format_plan(analyzed_plan)

        if analyze
          # Execute and get actual stats
          start_time = Time.now
          result = execute(analyzed_plan)
          elapsed_ms = ((Time.now - start_time) * 1000).round(2)

          plan_text = "EXPLAIN ANALYZE:\n#{plan_text}\n" +
                      "Execution Time: #{elapsed_ms}ms\n" +
                      "Rows: #{result[:row_count]}"
        end

        {
          rows: [{ "QUERY PLAN" => plan_text }],
          row_count: 1,
          column_names: ["QUERY PLAN"]
        }
      end

      # Scan operations
      def scan_table(plan)
        table_name = plan.table_name
        if @engine.catalog.respond_to?(:find_view) && (view = @engine.catalog.find_view(table_name))
          statement = RubyDB::SQL::Parser.new(RubyDB::SQL::Lexer.new(view.query).tokenize).parse.first
          return scan_table(Planner.new(@engine).plan(statement))
        end
        columns = @engine.table_columns(table_name)

        if plan.scan_type == :index && plan.index
          # Use index scan
          scan = Indexes::IndexScan.new(plan.index, :full)
          results = scan.execute
          row_ids = results.map { |r| r[:row_id] }

          # Fetch rows by row_id
          rows = []
          row_ids.each do |row_id|
            row = @engine.select_row(table_name, row_id, columns)
            rows << row if row
          end
          rows
        else
          # Sequential scan
          @engine.select_rows(table_name, columns)
        end
      end

      # Predicate evaluation
      def evaluate_predicate(predicate, row)
        case predicate
        when Predicate::Comparison
          left_val = evaluate_expression(predicate.left, row)
          right_val = evaluate_expression(predicate.right, row)
          compare_values(left_val, right_val, predicate.operator)
        when Predicate::And
          evaluate_predicate(predicate.left, row) && evaluate_predicate(predicate.right, row)
        when Predicate::Or
          evaluate_predicate(predicate.left, row) || evaluate_predicate(predicate.right, row)
        when Predicate::Not
          !evaluate_predicate(predicate.operand, row)
        when Predicate::Between
          val = evaluate_expression(predicate.expression, row)
          low = evaluate_expression(predicate.low, row)
          high = evaluate_expression(predicate.high, row)
          val >= low && val <= high
        when Predicate::In
          val = evaluate_expression(predicate.expression, row)
          predicate.values.any? { |v| val == evaluate_expression(v, row) }
        when Predicate::IsNull
          val = evaluate_expression(predicate.expression, row)
          predicate.negated ? !val.nil? : val.nil?
        when Predicate::Like
          val = evaluate_expression(predicate.expression, row).to_s
          pattern = evaluate_expression(predicate.pattern, row).to_s
          like_match?(val, pattern, predicate.case_sensitive)
        else
          true
        end
      end

      def evaluate_expression(expr, row = nil)
        case expr
        when SQL::AST::Literal
          expr.value
        when SQL::AST::Identifier
          row ? (row[expr.name] || row[expr.name.to_sym]) : nil
        when SQL::AST::UnaryOp
          apply_ast_unary_op(expr.operator, evaluate_expression(expr.operand, row))
        when SQL::AST::BinaryOp
          apply_ast_binary_op(
            expr.operator,
            evaluate_expression(expr.left, row),
            evaluate_expression(expr.right, row)
          )
        when SQL::AST::FunctionCall
          apply_function(expr.name, expr.arguments.map { |argument| evaluate_expression(argument, row) })
        when Expression::Literal
          expr.value
        when Expression::Column
          row ? row[expr.name] : nil
        when Expression::BinaryOp
          left = evaluate_expression(expr.left, row)
          right = evaluate_expression(expr.right, row)
          apply_binary_op(left, right, expr.operator)
        when Expression::UnaryOp
          operand = evaluate_expression(expr.operand, row)
          apply_unary_op(operand, expr.operator)
        when Expression::Function
          args = expr.arguments.map { |arg| evaluate_expression(arg, row) }
          apply_function(expr.name, args)
        when Expression::Parameter
          expr.value
        else
          nil
        end
      end

      # Helper methods
      def compare_values(left, right, operator)
        return false if left.nil? || right.nil?

        case operator
        when :eq then left == right
        when :ne then left != right
        when :lt then left < right
        when :lte then left <= right
        when :gt then left > right
        when :gte then left >= right
        else false
        end
      end

      def apply_binary_op(left, right, operator)
        return nil if left.nil? || right.nil?

        case operator
        when :plus then left + right
        when :minus then left - right
        when :multiply then left * right
        when :divide then left / right if right != 0
        when :modulo then left % right if right != 0
        when :concat then left.to_s + right.to_s
        else nil
        end
      end

      def apply_ast_unary_op(operator, value)
        return nil if value.nil?

        case operator
        when SQL::Token::Type::PLUS then value
        when SQL::Token::Type::MINUS then -value
        when SQL::Token::Type::NOT then !value
        else value
        end
      end

      def apply_ast_binary_op(operator, left, right)
        case operator
        when SQL::Token::Type::EQ then left == right
        when SQL::Token::Type::NE then left != right
        when SQL::Token::Type::LT then !left.nil? && !right.nil? && left < right
        when SQL::Token::Type::LTE then !left.nil? && !right.nil? && left <= right
        when SQL::Token::Type::GT then !left.nil? && !right.nil? && left > right
        when SQL::Token::Type::GTE then !left.nil? && !right.nil? && left >= right
        when SQL::Token::Type::AND then !!left && !!right
        when SQL::Token::Type::OR then !!left || !!right
        when SQL::Token::Type::PLUS then apply_binary_op(left, right, :plus)
        when SQL::Token::Type::MINUS then apply_binary_op(left, right, :minus)
        when SQL::Token::Type::STAR then apply_binary_op(left, right, :multiply)
        when SQL::Token::Type::SLASH then apply_binary_op(left, right, :divide)
        when SQL::Token::Type::PERCENT then apply_binary_op(left, right, :modulo)
        else nil
        end
      end

      def apply_unary_op(operand, operator)
        return nil if operand.nil?

        case operator
        when :negate then -operand
        when :not then !operand
        else operand
        end
      end

      def apply_function(name, args)
        case name.to_s.upcase
        when "COUNT"
          args.compact.size
        when "SUM"
          args.compact.sum
        when "AVG"
          vals = args.compact
          vals.empty? ? 0 : vals.sum / vals.size.to_f
        when "MIN"
          args.compact.min
        when "MAX"
          args.compact.max
        when "LOWER"
          args.first.to_s.downcase
        when "UPPER"
          args.first.to_s.upcase
        when "LENGTH"
          args.first.to_s.length
        when "COALESCE"
          args.find { |arg| !arg.nil? }
        when "NOW"
          Time.now
        when "CURRENT_DATE"
          Date.today
        when "CURRENT_TIME"
          Time.now
        else
          nil
        end
      end

      def like_match?(value, pattern, case_sensitive = true)
        return false if value.nil? || pattern.nil?

        str = case_sensitive ? value : value.downcase
        pat = case_sensitive ? pattern : pattern.downcase

        # Convert SQL LIKE pattern to regex
        regex_str = Regexp.escape(pat)
          .gsub('%', '.*')
          .gsub('_', '.')
        Regexp.new("^#{regex_str}$").match?(str)
      end

      def project_row(row, projections)
        result = {}
        projections.each do |proj|
          expression = proj.respond_to?(:expression) ? proj.expression : proj

          if expression.is_a?(SQL::AST::Star)
            result.merge!(row)
          elsif expression.is_a?(String) || expression.is_a?(Symbol)
            result[expression.to_s] = row[expression.to_s]
          else
            result[projection_name(proj)] = evaluate_expression(expression, row)
          end
        end
        result
      end

      def distinct_rows(rows)
        seen = Set.new
        rows.select do |row|
          key = row.to_hash
          if seen.include?(key)
            false
          else
            seen.add(key)
            true
          end
        end
      end

      def group_rows(rows, group_by, aggregates)
        groups = {}
        rows.each do |row|
          key = group_by.map { |col| row[col.to_s] }
          groups[key] ||= []
          groups[key] << row
        end

        result = []
        groups.each do |key, group_rows|
          result_row = {}
          group_by.each_with_index do |col, idx|
            result_row[col.to_s] = key[idx]
          end

          aggregates&.each do |agg|
            result_row[agg.alias || agg.name] = apply_aggregate(agg, group_rows)
          end

          result << result_row
        end
        result
      end

      def apply_aggregate(agg, rows)
        values = rows.map { |row| row[agg.column.to_s] }.compact

        case agg.name.to_s.upcase
        when "COUNT" then values.size
        when "SUM" then values.sum
        when "AVG" then values.empty? ? 0 : values.sum / values.size.to_f
        when "MIN" then values.min
        when "MAX" then values.max
        else nil
        end
      end

      def sort_rows(rows, order_by)
        rows.sort do |a, b|
          comparison = 0
          order_by.each do |order|
            col = (order.is_a?(Hash) ? order[:column] : order.column).to_s
            val_a = a[col]
            val_b = b[col]

            if val_a.nil? && val_b.nil?
              comparison = 0
            elsif val_a.nil?
              comparison = -1
            elsif val_b.nil?
              comparison = 1
            else
              comparison = val_a <=> val_b
            end

            direction = order.is_a?(Hash) ? order[:direction] : order.direction
            comparison = -comparison if direction == :desc
            break unless comparison == 0
          end
          comparison
        end
      end

      def get_column_names(plan)
        if plan.projections
          plan.projections.map { |projection| projection_name(projection) }
        else
          @engine.table_columns(plan.table_name).map(&:name)
        end
      end

      def projection_name(projection)
        return projection.to_s if projection.is_a?(String) || projection.is_a?(Symbol)

        expression = projection.respond_to?(:expression) ? projection.expression : projection
        alias_name = if projection.respond_to?(:alias_name)
          projection.alias_name
        elsif projection.respond_to?(:alias)
          projection.alias
        end
        return alias_name.to_s if alias_name

        return expression.name.to_s if expression.respond_to?(:name) && expression.name
        return expression.to_sql if expression.respond_to?(:to_sql)

        expression.to_s
      end

      def format_plan(plan)
        lines = []
        lines << "QUERY PLAN"
        lines << "=" * 40

        if plan.scan_type == :index
          lines << "Index Scan on #{plan.table_name} using #{plan.index.name}"
        else
          lines << "Seq Scan on #{plan.table_name}"
        end

        if plan.predicate
          lines << "  Filter: #{plan.predicate.to_s}"
        end

        if plan.order_by && plan.order_by.any?
          order_str = plan.order_by.map { |o| "#{o.column} #{o.direction}" }.join(", ")
          lines << "  Order By: #{order_str}"
        end

        if plan.limit
          lines << "  Limit: #{plan.limit}"
        end

        if plan.offset
          lines << "  Offset: #{plan.offset}"
        end

        lines << "  Estimated Cost: #{plan.estimated_cost}"
        lines << "  Estimated Rows: #{plan.estimated_rows}"
        lines.join("\n")
      end
    end
  end
end
