# frozen_string_literal: true

require "time"

module RubyDB
  module Execution
    # Executor - Executes query plans and returns results
    class Executor
      attr_reader :engine, :stats

      def initialize(engine, cte_rows: {}, deadline_at: nil, cancellation: nil)
        @engine = engine
        @accelerator = engine.respond_to?(:accelerator) ? engine.accelerator : nil
        @accelerator_dispatch = AcceleratorDispatch.new(@accelerator)
        @cte_rows = cte_rows
        @deadline_at = deadline_at && (deadline_at.is_a?(Time) ? deadline_at : Time.parse(deadline_at.to_s))
        @cancellation = cancellation
        @stats = {
          queries_executed: 0,
          rows_returned: 0,
          total_time_ms: 0,
          sequential_scans: 0,
          index_scans: 0,
          joins: 0,
          aggregations: 0,
          sorts: 0,
          accelerator_requests: 0,
          accelerator_fallbacks: 0
        }
        @lock = Mutex.new
        @current_transaction = nil
        @explain_mode = false
      end

      def execute(plan, transaction_id = nil)
        @lock.synchronize do
          check_deadline!
          start_time = Time.now
          @stats[:queries_executed] += 1
          @current_transaction = transaction_id

          result = case plan
          when Plan::With
            execute_with(plan)
          when Plan::Select
            execute_select(plan)
          when Plan::SetOperation
            execute_set_operation(plan)
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

      def execute_set_operation(plan)
        left = child_executor(@cte_rows).execute(plan.left_plan, @current_transaction)[:rows]
        right = child_executor(@cte_rows).execute(plan.right_plan, @current_transaction)[:rows]
        left_width = left.first&.size || plan.left_plan.columns.size
        right_width = right.first&.size || plan.right_plan.columns.size
        if left_width != right_width
          raise ExecutionError, "Set operation requires the same number of columns on both sides"
        end
        key = ->(row) { row.to_a }
        rows = case plan.operator
        when :union then plan.all ? left + right : (left + right).uniq { |row| key.call(row) }
        when :intersect then left.select { |row| right.any? { |other| key.call(other) == key.call(row) } }.uniq { |row| key.call(row) }
        when :except then left.reject { |row| right.any? { |other| key.call(other) == key.call(row) } }.uniq { |row| key.call(row) }
        else raise ExecutionError, "Unsupported set operation: #{plan.operator}"
        end
        {rows: rows, row_count: rows.size, column_names: rows.first&.keys || []}
      end

      def execute_with(plan)
        available_ctes = @cte_rows.dup
        plan.ctes.each do |name, cte_plan|
          available_ctes[name.to_s] = if plan.recursive && cte_plan.is_a?(Plan::SetOperation) && cte_plan.operator == :union
            execute_recursive_cte(name.to_s, cte_plan, available_ctes)
          else
            child_executor(available_ctes).execute(cte_plan, @current_transaction)[:rows]
          end
        end
        child_executor(available_ctes).execute(plan.query_plan, @current_transaction)
      end

      def execute_recursive_cte(name, cte_plan, available_ctes)
        unless cte_plan.is_a?(Plan::SetOperation) && cte_plan.operator == :union
          raise ExecutionError, "Recursive CTE requires UNION or UNION ALL"
        end

        anchor = child_executor(available_ctes).execute(cte_plan.left_plan, @current_transaction)[:rows]
        accumulated = anchor.dup
        working = anchor
        output_columns = anchor.first&.keys || cte_plan.left_plan.columns.map(&:to_s)
        max_iterations = Integer(@engine.instance_variable_get(:@config)[:max_recursive_iterations] || 10_000)
        iterations = 0

        while working.any?
          iterations += 1
          raise ExecutionError, "Recursive CTE exceeded #{max_iterations} iterations" if iterations > max_iterations

          recursive_scope = available_ctes.merge(name => working)
          next_rows = child_executor(recursive_scope).execute(cte_plan.right_plan, @current_transaction)[:rows]
          next_rows = next_rows.map do |row|
            output_columns.zip(row.values).to_h
          end
          if cte_plan.all
            accumulated.concat(next_rows)
            working = next_rows
          else
            existing = accumulated.map { |row| row.to_a }
            working = next_rows.reject { |row| existing.include?(row.to_a) }
            accumulated.concat(working)
          end
        end

        accumulated
      end

      def execute_select(plan)
        @accelerator_window_applied = false
        if (count_result = metadata_count_result(plan))
          return count_result
        end
        @stats[:sequential_scans] += 1 if plan.scan_type == :sequential
        @stats[:index_scans] += 1 if plan.scan_type == :index

        # Qualify source rows before evaluating predicates. This preserves
        # SQL's table/alias namespace while retaining unqualified keys for
        # existing single-table callers.
        snapshot_rows = accelerate_snapshot_scan(plan)
        rows = snapshot_rows || scan_table(plan)
        accelerated = snapshot_rows || accelerate_scan(rows, plan)
        aggregate_accelerated = false
        unless accelerated
          accelerated_rows = accelerate_aggregate(rows, plan)
          if accelerated_rows
            rows = accelerated_rows
            aggregate_accelerated = true
          end
        end
        if accelerated
          rows = accelerated
        end
        rows = qualify_rows(rows, plan.source_reference || plan.table_name) unless aggregate_accelerated
        plan.joins.each do |join|
          check_deadline!
          right_rows = qualify_rows(scan_table(Plan::Select.new(join[:table].name, [])), join[:table])
          rows = accelerate_join(rows, right_rows, join) || execute_join(rows, right_rows, join)
        end

        # Apply filters (WHERE clause)
        if plan.predicate && !accelerated && !aggregate_accelerated
          rows = rows.each_with_index.filter_map do |row, index|
            check_deadline! if (index & 255).zero?
            row if evaluate_predicate(plan.predicate, row)
          end
        end

        apply_window_functions!(rows, plan.projections) if plan.projections

        # ORDER BY is evaluated against the source rows, so a column used
        # solely for ordering remains available even when it is not selected.
        aggregating = plan.aggregates && !plan.aggregates.empty?
        if plan.order_by && !plan.order_by.empty? && !aggregating && !accelerated
          rows = sort_rows(rows, plan.order_by)
        end

        if aggregating && !aggregate_accelerated
          rows = aggregate_rows(rows, plan.group_by || [], plan.projections)
          rows = rows.select { |row| evaluate_predicate(plan.having, row) } if plan.having
        elsif !aggregating && plan.projections
          # Apply projections (SELECT columns)
          rows = rows.each_with_index.map do |row, index|
            check_deadline! if (index & 255).zero?
            project_row(row, plan.projections)
          end
        end

        # Apply DISTINCT
        if plan.distinct
          rows = distinct_rows(rows)
        end

        # Apply GROUP BY
        # Apply ORDER BY
        if plan.order_by && !plan.order_by.empty? && aggregating
          rows = sort_rows(rows, plan.order_by)
        end

        # Apply LIMIT and OFFSET
        if plan.limit && !@accelerator_window_applied
          offset = plan.offset || 0
          rows = rows[offset, plan.limit] || []
        elsif plan.offset
          rows = rows[plan.offset..] || []
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
        rows = plan.rows || [plan.values]
        implicit_transaction = rows.size > 1 && !@engine.in_transaction?
        @engine.begin_transaction if implicit_transaction

        begin
          inserted = if rows.size > 1 && plan.on_conflict.nil?
            execute_simple_insert_batch(table_name, columns, rows)
          else
            rows.map { |values| execute_single_insert(plan, table_name, columns, values) }
          end
          unless !implicit_transaction || @engine.commit_transaction
            raise ExecutionError, "Implicit multi-row INSERT transaction could not commit"
          end

          {
            row_count: inserted.sum { |result| result[:row_count] },
            affected_rows: inserted.sum { |result| result[:affected_rows] },
            row_ids: inserted.filter_map { |result| result[:row_id] },
            row_id: inserted.reverse_each.map { |result| result[:row_id] }.compact.first,
            inserted_ids: inserted.filter_map { |result| result[:inserted_id] },
            inserted_id: inserted.reverse_each.map { |result| result[:inserted_id] }.compact.first,
            message: "INSERT #{inserted.sum { |result| result[:affected_rows] }}"
          }
        # Roll back even when the request is interrupted, then re-raise it.
        # rubocop:disable Lint/RescueException
        rescue Exception
          @engine.rollback_transaction if implicit_transaction && @engine.in_transaction?
          raise
          # rubocop:enable Lint/RescueException
        end
      end

      def execute_single_insert(plan, table_name, columns, values)
        row_data = build_insert_row(columns, values)

        # Insert into engine
        table_columns = @engine.table_columns(table_name)
        row_id = @engine.insert_row(table_name, table_columns, row_data)
        primary_key = table_columns.find(&:primary_key?)
        inserted_row = @engine.select_row(table_name, row_id, table_columns)
        inserted_id = if primary_key && inserted_row
          inserted_row[primary_key.name] || inserted_row[primary_key.name.to_sym]
        end

        {
          row_count: 1,
          affected_rows: 1,
          row_id: row_id,
          inserted_id: inserted_id,
          message: "INSERT 1"
        }
      rescue DatabaseError => error
        raise unless error.message.match?(/duplicate|unique|primary key/i)
        return {row_count: 0, affected_rows: 0, message: "INSERT 0 (conflict ignored)"} if plan.on_conflict == :nothing
        raise unless plan.on_conflict.is_a?(Hash) && plan.on_conflict[:action] == :update

        target = plan.on_conflict[:target]
        target = @engine.table_columns(table_name).select(&:primary_key?).map(&:name) if target.empty?
        if target.empty?
          target = @engine.table_columns(table_name).select(&:unique?).map(&:name)
        end
        if target.empty? && @engine.respond_to?(:index_manager)
          target = @engine.index_manager.get_indexes_for_table(table_name)
            .select(&:unique?).min_by { |index| index.columns.size }&.columns || []
        end
        raise ExecutionError, "ON CONFLICT DO UPDATE requires a conflict target or primary key" if target.empty?
        target_conditions = target.each_with_object({}) do |column, conditions|
          conditions[column] = row_value(row_data, column, column.to_s)
        end
        existing = @engine.select_rows(table_name, @engine.table_columns(table_name), target_conditions).find do |row|
          target.all? do |column|
            row_value(row, column, column.to_s) == row_value(row_data, column, column.to_s)
          end
        end
        raise error unless existing

        context = existing.merge(row_data.transform_keys(&:to_s).transform_keys { |key| "excluded.#{key}" })
        values = plan.on_conflict[:assignments].each_with_object({}) do |assignment, updates|
          updates[assignment.column] = evaluate_expression(assignment.value, context)
        end
        row_id = existing[:_row_id] || existing["_row_id"]
        @engine.update_row(table_name, row_id, values)
        inserted_id = target.map { |column| existing[column] || existing[column.to_sym] }.first
        {row_count: 1, affected_rows: 1, row_id: row_id, inserted_id: inserted_id, message: "INSERT 0 UPDATE 1"}
      end

      # The engine still validates and WAL-logs every tuple. This path removes
      # repeated metadata publication and avoids recreating table metadata for
      # each VALUES tuple in an otherwise ordinary multi-row INSERT.
      def execute_simple_insert_batch(table_name, columns, value_rows)
        table_columns = @engine.table_columns(table_name)
        row_data = value_rows.map { |values| build_insert_row(columns, values) }
        row_ids = @engine.insert_rows(table_name, table_columns, row_data)
        primary_key = table_columns.find(&:primary_key?)

        row_ids.map do |row_id|
          inserted_row = primary_key && @engine.select_row(table_name, row_id, table_columns)
          inserted_id = if primary_key && inserted_row
            inserted_row[primary_key.name] || inserted_row[primary_key.name.to_sym]
          end
          {row_count: 1, affected_rows: 1, row_id: row_id, inserted_id: inserted_id, message: "INSERT 1"}
        end
      end

      def build_insert_row(columns, values)
        columns.each_with_index.each_with_object({}) do |(column, index), row|
          row[column] = evaluate_expression(values[index])
        end
      end

      def execute_update(plan)
        table_name = plan.table_name
        assignments = plan.assignments
        predicate = plan.predicate

        # Get rows to update
        rows = scan_table(Plan::Select.new(table_name, []), predicate: predicate)
        rows = rows.select { |row| evaluate_predicate(predicate, row) } if predicate

        updated_count = 0
        rows.each do |row|
          # Apply updates
          assignments.each do |assignment|
            column = assignment.is_a?(Hash) ? (assignment[:column] || assignment["column"]) : assignment.column
            value = assignment.is_a?(Hash) ? (assignment[:value] || assignment["value"]) : assignment.value
            row[column] = evaluate_expression(value, row)
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
        rows = scan_table(Plan::Select.new(table_name, []), predicate: predicate)
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
        {row_count: 0, message: "CREATE DATABASE #{plan.database_name}"}
      end

      def execute_drop_database(plan)
        @engine.catalog.drop_database(plan.database_name, **(plan.options || {}))
        {row_count: 0, message: "DROP DATABASE #{plan.database_name}"}
      end

      def execute_create_schema(plan)
        @engine.catalog.create_schema(plan.schema_name, **(plan.options || {}))
        {row_count: 0, message: "CREATE SCHEMA #{plan.schema_name}"}
      end

      def execute_drop_schema(plan)
        @engine.catalog.drop_schema(plan.schema_name, **(plan.options || {}))
        {row_count: 0, message: "DROP SCHEMA #{plan.schema_name}"}
      end

      def execute_create_view(plan)
        query = plan.query.respond_to?(:to_sql) ? plan.query.to_sql : plan.query
        @engine.catalog.create_view(plan.view_name, query, **(plan.options || {}))
        {row_count: 0, message: "CREATE VIEW #{plan.view_name}"}
      end

      def execute_drop_view(plan)
        @engine.catalog.drop_view(plan.view_name, **(plan.options || {}))
        {row_count: 0, message: "DROP VIEW #{plan.view_name}"}
      end

      def execute_create_trigger(plan)
        definition = "EXECUTE FUNCTION #{plan.function_name}()"
        @engine.catalog.create_trigger(plan.trigger_name, plan.event, plan.target_table, definition, timing: plan.timing, function_name: plan.function_name)
        {row_count: 0, message: "CREATE TRIGGER #{plan.trigger_name}"}
      end

      def execute_drop_trigger(plan)
        @engine.catalog.drop_trigger(plan.trigger_name, **(plan.options || {}))
        {row_count: 0, message: "DROP TRIGGER #{plan.trigger_name}"}
      end

      def execute_vacuum(_plan)
        result = @engine.vacuum
        {row_count: 0, vacuum: result, message: "VACUUM"}
      end

      def execute_alter_table_add_column(plan)
        @engine.add_column(plan.table_name, plan.column_name, plan.column_type, plan.options)
        {row_count: 0, message: "ALTER TABLE #{plan.table_name} ADD COLUMN #{plan.column_name}"}
      end

      def execute_alter_table_drop_column(plan)
        @engine.drop_column(plan.table_name, plan.column_name)
        {row_count: 0, message: "ALTER TABLE #{plan.table_name} DROP COLUMN #{plan.column_name}"}
      end

      def execute_alter_table_add_constraint(plan)
        @engine.add_constraint(plan.table_name, plan.constraint)
        {row_count: 0, message: "ALTER TABLE #{plan.table_name} ADD CONSTRAINT #{plan.constraint.name}"}
      end

      def execute_alter_table_drop_constraint(plan)
        @engine.drop_constraint(plan.table_name, plan.constraint_name)
        {row_count: 0, message: "ALTER TABLE #{plan.table_name} DROP CONSTRAINT #{plan.constraint_name}"}
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
        {row_count: 0, message: "SAVEPOINT #{plan.name}"}
      end

      def execute_rollback_to_savepoint(plan)
        @engine.rollback_to_savepoint(plan.name)
        {row_count: 0, message: "ROLLBACK TO SAVEPOINT #{plan.name}"}
      end

      def execute_release_savepoint(plan)
        @engine.release_savepoint(plan.name)
        {row_count: 0, message: "RELEASE SAVEPOINT #{plan.name}"}
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

          plan_text = "EXPLAIN ANALYZE:\n#{plan_text}\n" \
            "Execution Time: #{elapsed_ms}ms\n" \
            "Rows: #{result[:row_count]}"
        end

        {
          rows: [{"QUERY PLAN" => plan_text}],
          row_count: 1,
          column_names: ["QUERY PLAN"]
        }
      end

      # Scan operations
      def accelerate_snapshot_scan(plan)
        return nil unless @accelerator
        return nil unless @accelerator.read_pipeline?
        return nil unless plan.table_name && plan.joins.empty?
        min_rows = @accelerator.min_rows_for(:snapshot_scan)
        return nil if plan.limit && plan.order_by.empty? &&
          plan.limit + (plan.offset || 0) < min_rows
        return nil if @cte_rows.any?
        return nil if plan.distinct || plan.having || (plan.aggregates && !plan.aggregates.empty?)
        estimated_rows = plan.estimated_rows || @engine.table_live_row_count(plan.table_name)
        return nil unless @accelerator.preferred_for?(:snapshot_scan, input_rows: estimated_rows)

        filters = accelerator_filters(plan.predicate)
        order_by = accelerator_order_by(plan.order_by)
        return nil if filters.nil? || order_by.nil?

        columns = @engine.table_columns(plan.table_name)
        column_names = columns.map { |column| column.name.to_s }
        column_types = columns.each_with_object({}) { |column, types| types[column.name.to_s] = column.type_class.to_s }
        index_name = if plan.scan_type == :index && plan.index&.type&.to_sym == :btree
          plan.index.name.to_s
        end
        storage_order = order_by.map { |order| order.merge(column: order[:column].to_s.split(".").last) }
        windowed_projection = Array(plan.projections).any? do |projection|
          expression = projection.respond_to?(:expression) ? projection.expression : projection
          expression.is_a?(SQL::AST::FunctionCall) && expression.window
        end
        window_limit = if !windowed_projection && !plan.distinct && !(plan.aggregates && !plan.aggregates.empty?)
          plan.limit
        end
        window_eligible = !windowed_projection && !plan.distinct && !(plan.aggregates && !plan.aggregates.empty?)
        window_offset = (window_limit || window_eligible) ? (plan.offset || 0) : 0

        @stats[:accelerator_requests] += 1
        calibrating = !@accelerator.manager.performance_calibrated?(:snapshot_scan)
        started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        result = nil
        @engine.with_accelerator_snapshot do |manifest|
          result = @accelerator.snapshot_scan(
            manifest,
            table: plan.table_name,
            columns: column_names,
            column_types: column_types,
            filters: filters,
            order_by: storage_order,
            index_name: index_name,
            limit: window_limit,
            offset: window_offset,
            batch_size: window_limit ? [window_limit, 1024].min : 1024
          )
        end
        return nil unless result
        @accelerator_window_applied = !window_limit.nil? || window_offset.positive?
        return result[:rows] unless calibrating

        ruby_started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        ruby_rows = ruby_scan_rows(@engine.select_rows(plan.table_name, columns), plan, apply_window: !window_limit.nil?)
        go_ms = elapsed_milliseconds(started_at)
        ruby_ms = elapsed_milliseconds(ruby_started_at)
        unless accelerator_results_equivalent?(result[:rows], ruby_rows)
          @stats[:accelerator_fallbacks] += 1
          @accelerator.manager.record_performance(:snapshot_scan, ruby_ms: ruby_ms, go_ms: Float::INFINITY)
          @accelerator.manager.record_performance(:scan, ruby_ms: ruby_ms, go_ms: Float::INFINITY)
          raise ExecutionError, "RubyDB accelerator returned a different snapshot scan result" if @accelerator.manager.mode == "required"

          return ruby_rows
        end
        @accelerator.manager.record_performance(:snapshot_scan, ruby_ms: ruby_ms, go_ms: go_ms)
        @accelerator.manager.record_performance(:scan, ruby_ms: ruby_ms, go_ms: go_ms)
        @accelerator.manager.acceleration_preferred?(:snapshot_scan) ? result[:rows] : ruby_rows
      rescue RubyDB::Accelerator::Error, RubyDB::StorageError
        @stats[:accelerator_fallbacks] += 1
        raise if @accelerator.manager.mode == "required"

        nil
      end

      def accelerate_scan(rows, plan)
        return nil unless @accelerator
        return nil unless @accelerator.read_pipeline?
        return nil unless @accelerator.preferred_for?(:scan, input_rows: rows.size)
        return nil unless plan.joins.empty?
        return nil if plan.distinct || (plan.aggregates && !plan.aggregates.empty?)

        filters = accelerator_filters(plan.predicate)
        order_by = accelerator_order_by(plan.order_by)
        return nil if filters.nil? || order_by.nil?
        return nil if filters.empty? && order_by.empty?

        calibrating = !@accelerator.manager.performance_calibrated?(:scan)
        @stats[:accelerator_requests] += 1
        started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        result = @accelerator.rows_pipeline(
          rows,
          filters: filters,
          order_by: order_by,
          # Ruby applies LIMIT/OFFSET after projection and aggregation. Do
          # not apply them in Go here or the final Ruby stage would paginate
          # the result twice.
          limit: nil,
          offset: 0
        )
        return nil unless result
        return result[:rows] unless calibrating

        ruby_started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        ruby_rows = ruby_scan_rows(rows, plan)
        go_ms = elapsed_milliseconds(started_at)
        ruby_ms = elapsed_milliseconds(ruby_started_at)
        if !accelerator_results_equivalent?(result[:rows], ruby_rows)
          @stats[:accelerator_fallbacks] += 1
          @accelerator.manager.record_performance(:scan, ruby_ms: ruby_ms, go_ms: Float::INFINITY)
          if @accelerator.manager.mode == "required"
            raise ExecutionError, "RubyDB accelerator returned a different scan result"
          end

          return ruby_rows
        end
        @accelerator.manager.record_performance(:scan, ruby_ms: ruby_ms, go_ms: go_ms)
        @accelerator.manager.acceleration_preferred?(:scan) ? result[:rows] : ruby_rows
      rescue RubyDB::Accelerator::Error
        @stats[:accelerator_fallbacks] += 1
        raise if @accelerator.manager.mode == "required"

        nil
      end

      def accelerate_aggregate(rows, plan)
        return nil unless @accelerator
        return nil unless @accelerator.read_pipeline?
        return nil unless @accelerator.preferred_for?(:aggregate, input_rows: rows.size)
        return nil unless plan.joins.empty?
        return nil if plan.distinct || plan.having || plan.order_by&.any?
        return nil unless plan.aggregates && !plan.aggregates.empty?

        filters = accelerator_filters(plan.predicate)
        group_by = Array(plan.group_by).map { |expression| accelerator_identifier(expression) }
        return nil if filters.nil? || group_by.any?(&:nil?)

        definitions = []
        projections = Array(plan.projections)
        projections.each do |projection|
          expression = projection.respond_to?(:expression) ? projection.expression : projection
          if aggregate_function?(expression)
            return nil if expression.distinct || expression.arguments.length > 1

            argument = expression.arguments.first
            column = argument.is_a?(SQL::AST::Star) ? "*" : accelerator_identifier(argument)
            return nil unless column
            alias_name = projection.respond_to?(:alias_name) ? projection.alias_name : nil
            return nil if alias_name.nil? || alias_name.to_s.empty?

            definitions << {function: expression.name.to_s.upcase, column: column, alias: alias_name.to_s}
          else
            column = accelerator_identifier(expression)
            return nil unless column && group_by.include?(column)
          end
        end

        return nil if definitions.empty?

        calibrating = !@accelerator.manager.performance_calibrated?(:aggregate)
        @stats[:accelerator_requests] += 1
        started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        result = @accelerator.rows_pipeline(
          rows,
          filters: filters,
          group_by: group_by,
          aggregates: definitions,
          limit: nil,
          offset: 0
        )
        accelerated_aggregate_rows = result && result[:aggregates]
        return nil unless accelerated_aggregate_rows

        projected_rows = accelerated_aggregate_rows.map do |row|
          projections.each_with_object({}) do |projection, projected|
            name = projection_name(projection)
            projected[name] = row[name]
          end
        end
        return projected_rows unless calibrating

        ruby_started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        filtered_rows = plan.predicate ? rows.select { |row| evaluate_predicate(plan.predicate, row) } : rows
        ruby_rows = aggregate_rows(filtered_rows, plan.group_by || [], projections)
        go_ms = elapsed_milliseconds(started_at)
        ruby_ms = elapsed_milliseconds(ruby_started_at)
        if !accelerator_results_equivalent?(projected_rows, ruby_rows)
          @stats[:accelerator_fallbacks] += 1
          @accelerator.manager.record_performance(:aggregate, ruby_ms: ruby_ms, go_ms: Float::INFINITY)
          raise ExecutionError, "RubyDB accelerator returned a different aggregate result" if @accelerator.manager.mode == "required"

          return ruby_rows
        end
        @accelerator.manager.record_performance(:aggregate, ruby_ms: ruby_ms, go_ms: go_ms)
        @accelerator.manager.acceleration_preferred?(:aggregate) ? projected_rows : ruby_rows
      rescue RubyDB::Accelerator::Error
        @stats[:accelerator_fallbacks] += 1
        raise if @accelerator.manager.mode == "required"

        nil
      end

      def ruby_scan_rows(rows, plan, apply_window: false)
        source_rows = rows.map { |row| row.each_with_object({}) { |(key, value), copy| copy[key.to_s] = value } }
        result = plan.predicate ? source_rows.select { |row| evaluate_predicate(plan.predicate, row) } : source_rows
        order_by = accelerator_order_by(plan.order_by)
        result = sort_rows(result, order_by) if order_by && !order_by.empty?
        if apply_window
          offset = plan.offset || 0
          result = result[offset, plan.limit] || [] if plan.limit
          result = result[offset..] || [] if !plan.limit && offset.positive?
        end
        result
      end

      def accelerate_join(left_rows, right_rows, join)
        return nil unless @accelerator
        return nil unless @accelerator.read_pipeline?
        input_rows = left_rows.size + right_rows.size
        return nil unless @accelerator.preferred_for?(:join, input_rows: input_rows)
        return nil unless join[:type].to_sym == :inner

        predicate = join[:predicate]
        return nil unless predicate.is_a?(Predicate::Comparison) && predicate.operator.to_s.casecmp?("eq")

        left_key = accelerator_identifier(predicate.left)
        right_key = accelerator_identifier(predicate.right)
        return nil unless left_key && right_key
        return nil unless left_rows.first&.key?(left_key) && right_rows.first&.key?(right_key)
        calibrating = !@accelerator.manager.performance_calibrated?(:join)
        @stats[:accelerator_requests] += 1
        started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        result = @accelerator.hash_join(left_rows, right_rows, left_key: left_key, right_key: right_key)
        return nil unless result
        return result[:rows] unless calibrating

        ruby_started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        ruby_rows = execute_join(left_rows, right_rows, join)
        go_ms = elapsed_milliseconds(started_at)
        ruby_ms = elapsed_milliseconds(ruby_started_at)
        unless accelerator_results_equivalent?(result[:rows], ruby_rows)
          @stats[:accelerator_fallbacks] += 1
          @accelerator.manager.record_performance(:join, ruby_ms: ruby_ms, go_ms: Float::INFINITY)
          raise ExecutionError, "RubyDB accelerator returned a different join result" if @accelerator.manager.mode == "required"

          return ruby_rows
        end
        @accelerator.manager.record_performance(:join, ruby_ms: ruby_ms, go_ms: go_ms)
        @accelerator.manager.acceleration_preferred?(:join) ? result[:rows] : ruby_rows
      rescue RubyDB::Accelerator::Error
        @stats[:accelerator_fallbacks] += 1
        raise if @accelerator.manager.mode == "required"

        nil
      end

      def elapsed_milliseconds(started_at)
        (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000.0
      end

      def accelerator_results_equivalent?(left, right)
        @accelerator_dispatch.equivalent?(left, right)
      end

      def accelerator_filters(predicate)
        return [] unless predicate

        case predicate
        when Predicate::And
          left = accelerator_filters(predicate.left)
          right = accelerator_filters(predicate.right)
          return nil if left.nil? || right.nil?

          left + right
        when Predicate::Comparison
          column = accelerator_identifier(predicate.left)
          value = accelerator_literal(predicate.right)
          return nil if column.nil? || value.equal?(:unsupported)

          [{column: column, operator: predicate.operator.to_s, value: value}]
        when Predicate::Between
          column = accelerator_identifier(predicate.expression)
          low = accelerator_literal(predicate.low)
          high = accelerator_literal(predicate.high)
          return nil if column.nil? || low.equal?(:unsupported) || high.equal?(:unsupported)

          [
            {column: column, operator: "gte", value: low},
            {column: column, operator: "lte", value: high}
          ]
        when Predicate::IsNull
          column = accelerator_identifier(predicate.expression)
          return nil unless column

          [{column: column, operator: predicate.negated ? "is_not_null" : "is_null"}]
        when Predicate::Like
          column = accelerator_identifier(predicate.expression)
          value = accelerator_literal(predicate.pattern)
          return nil if column.nil? || value.equal?(:unsupported)

          [{column: column, operator: "like", value: value}]
        end
      end

      def accelerator_order_by(order_by)
        order_by.map do |order|
          expression = order.is_a?(Hash) ? order[:column] : order.expression
          column = accelerator_identifier(expression)
          return nil unless column

          direction = order.is_a?(Hash) ? order[:direction] : order.direction
          {column: column, direction: direction.to_s}
        end
      end

      def accelerator_identifier(expression)
        return expression.to_s if expression.is_a?(String) || expression.is_a?(Symbol)
        return expression.name.to_s if expression.is_a?(Expression::Column)
        return nil unless expression.is_a?(SQL::AST::Identifier)

        expression.name.to_s
      end

      def accelerator_literal(expression)
        return expression.value if expression.is_a?(Expression::Literal)
        return :unsupported unless expression.is_a?(SQL::AST::Literal)

        expression.value
      end

      def scan_table(plan, predicate: plan.predicate)
        table_name = plan.table_name
        return [{}] unless table_name
        return @cte_rows.fetch(table_name.to_s) if @cte_rows.key?(table_name.to_s)
        if @engine.catalog.respond_to?(:find_view) && (view = @engine.catalog.find_view(table_name))
          statement = RubyDB::SQL::Parser.new(RubyDB::SQL::Lexer.new(view.query).tokenize).parse.first
          return scan_table(Planner.new(@engine).plan(statement))
        end
        columns = @engine.table_columns(table_name)

        # Only exact-key conditions are pushed down here. A full index walk
        # followed by one row fetch per entry is slower than a page scan and
        # can accidentally change row order for LIMIT without ORDER BY.
        conditions = exact_index_conditions(table_name, predicate)
        return @engine.select_rows(table_name, columns, conditions) if conditions

        if predicate.nil? && plan.limit && plan.joins.empty? && plan.order_by.empty? &&
            !plan.distinct && plan.group_by.empty? && (plan.aggregates.nil? || plan.aggregates.empty?) &&
            Array(plan.projections).none? { |projection|
              expression = projection.respond_to?(:expression) ? projection.expression : projection
              expression.is_a?(SQL::AST::FunctionCall) && expression.window
            }
          return @engine.select_rows(table_name, columns, limit: plan.limit + (plan.offset || 0))
        end

        @engine.select_rows(table_name, columns)
      end

      def metadata_count_result(plan)
        return nil unless plan.table_name && plan.predicate.nil? && plan.joins.empty?
        return nil unless plan.group_by.empty? && plan.having.nil? && !plan.distinct
        return nil unless plan.order_by.empty? && !@engine.in_transaction?
        return nil unless Array(plan.projections).size == 1

        projection = plan.projections.first
        expression = projection.respond_to?(:expression) ? projection.expression : projection
        return nil unless expression.is_a?(SQL::AST::FunctionCall) &&
          expression.name.to_s.casecmp?("COUNT") && !expression.distinct && !expression.window &&
          expression.arguments.size == 1 && expression.arguments.first.is_a?(SQL::AST::Star)

        rows = [{projection_name(projection) => @engine.table_live_row_count(plan.table_name)}]
        rows = rows[(plan.offset || 0), plan.limit] || [] if plan.limit
        rows = rows[(plan.offset || 0)..] || [] if !plan.limit && plan.offset
        {rows: rows, row_count: rows.size, column_names: get_column_names(plan)}
      end

      def exact_index_conditions(table_name, predicate)
        return nil unless predicate

        equalities = {}
        collect_equalities(predicate, equalities)
        return nil if equalities.empty?

        index = @engine.index_manager.get_indexes_for_table(table_name).find do |candidate|
          candidate.columns.all? { |column| equalities.key?(column.to_s) }
        end
        return nil unless index

        index.columns.each_with_object({}) do |column, conditions|
          conditions[column] = equalities.fetch(column.to_s)
        end
      end

      def collect_equalities(predicate, equalities)
        case predicate
        when Predicate::And
          collect_equalities(predicate.left, equalities)
          collect_equalities(predicate.right, equalities)
        when Predicate::Comparison
          return unless predicate.operator == :eq

          left, right = predicate.left, predicate.right
          left, right = right, left if left.is_a?(Expression::Literal)
          return unless left.is_a?(Expression::Column) && right.is_a?(Expression::Literal)

          equalities[left.name.to_s] = right.value
        end
      end

      def qualify_rows(rows, table_reference)
        table_name = table_reference.respond_to?(:name) ? table_reference.name : table_reference
        alias_name = table_reference.respond_to?(:alias_name) ? table_reference.alias_name : nil
        rows.map do |row|
          row.each_with_object({}) do |(key, value), qualified|
            key = key.to_s
            qualified[key] = value
            qualified["#{table_name}.#{key}"] = value
            qualified["#{alias_name}.#{key}"] = value if alias_name
          end
        end
      end

      def execute_join(left_rows, right_rows, join)
        return left_rows.flat_map { |left_row| right_rows.map { |right_row| merge_join_rows(left_row, right_row) } } if join[:type] == :cross

        result = []
        matched_right = Array.new(right_rows.length, false)
        left_rows.each do |left_row|
          check_deadline!
          matches = right_rows.each_index.select do |index|
            evaluate_predicate(join[:predicate], merge_join_rows(left_row, right_rows[index]))
          end
          if matches.empty?
            result << merge_join_rows(left_row, nil) if %i[left full].include?(join[:type])
          else
            matches.each do |index|
              matched_right[index] = true
              result << merge_join_rows(left_row, right_rows[index])
            end
          end
        end
        if %i[right full].include?(join[:type])
          right_rows.each_with_index do |right_row, index|
            result << merge_join_rows(nil, right_row) unless matched_right[index]
          end
        end
        result
      end

      def merge_join_rows(left_row, right_row)
        (left_row || {}).merge(right_row || {}) { |_key, left_value, _right_value| left_value }
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
          return nil unless row

          qualified_name = expr.table && "#{expr.table}.#{expr.name}"
          row_value(row, qualified_name, expr.name, expr.name.to_sym)
        when SQL::AST::UnaryOp
          apply_ast_unary_op(expr.operator, evaluate_expression(expr.operand, row))
        when SQL::AST::BinaryOp
          apply_ast_binary_op(
            expr.operator,
            evaluate_expression(expr.left, row),
            evaluate_expression(expr.right, row)
          )
        when SQL::AST::FunctionCall
          if expr.window
            row && row[window_key(expr)]
          else
            apply_function(expr.name, expr.arguments.map { |argument| evaluate_expression(argument, row) })
          end
        when SQL::AST::Subquery
          result = child_executor(@cte_rows).execute(Planner.new(@engine).plan(expr.query))
          rows = result[:rows]
          raise ExecutionError, "Scalar subquery returned more than one row" if rows.size > 1
          rows.empty? ? nil : rows.first.values.first
        when Expression::Literal
          expr.value
        when Expression::Column
          return nil unless row

          qualified_name = expr.table && "#{expr.table}.#{expr.name}"
          row_value(row, qualified_name, expr.name, expr.name.to_sym)
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
        # SQL comparisons involving NULL evaluate to UNKNOWN, represented by
        # nil here. WHERE filtering already treats UNKNOWN as non-matching.
        when SQL::Token::Type::EQ then (left.nil? || right.nil?) ? nil : left == right
        when SQL::Token::Type::NE then (left.nil? || right.nil?) ? nil : left != right
        when SQL::Token::Type::LT then !left.nil? && !right.nil? && left < right
        when SQL::Token::Type::LTE then !left.nil? && !right.nil? && left <= right
        when SQL::Token::Type::GT then !left.nil? && !right.nil? && left > right
        when SQL::Token::Type::GTE then !left.nil? && !right.nil? && left >= right
        when SQL::Token::Type::AND then sql_and(left, right)
        when SQL::Token::Type::OR then sql_or(left, right)
        when SQL::Token::Type::PLUS then apply_binary_op(left, right, :plus)
        when SQL::Token::Type::MINUS then apply_binary_op(left, right, :minus)
        when SQL::Token::Type::STAR then apply_binary_op(left, right, :multiply)
        when SQL::Token::Type::SLASH then apply_binary_op(left, right, :divide)
        when SQL::Token::Type::PERCENT then apply_binary_op(left, right, :modulo)
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

      def sql_and(left, right)
        return false if left == false || right == false
        return nil if left.nil? || right.nil?

        !!left && !!right
      end

      def sql_or(left, right)
        return true if left == true || right == true
        return nil if left.nil? || right.nil?

        !!left || !!right
      end

      def row_value(row, *keys)
        keys.compact.each do |key|
          return row[key] if row.respond_to?(:key?) && row.key?(key)
        end
        nil
      end

      def child_executor(cte_rows)
        self.class.new(
          @engine,
          cte_rows: cte_rows,
          deadline_at: @deadline_at,
          cancellation: @cancellation
        )
      end

      def check_deadline!
        if @cancellation&.cancelled?
          raise ExecutionError.new("Request cancelled by client", code: "cancelled")
        end

        return unless @deadline_at && Time.now >= @deadline_at

        raise ExecutionError.new("Request deadline exceeded during execution", code: "deadline_exceeded")
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
        end
      end

      def like_match?(value, pattern, case_sensitive = true)
        return false if value.nil? || pattern.nil?

        str = case_sensitive ? value : value.downcase
        pat = case_sensitive ? pattern : pattern.downcase

        # Convert SQL LIKE pattern to regex
        regex_str = Regexp.escape(pat)
          .gsub("%", ".*")
          .gsub("_", ".")
        Regexp.new("^#{regex_str}$").match?(str)
      end

      def project_row(row, projections)
        result = {}
        projections.each do |proj|
          expression = proj.respond_to?(:expression) ? proj.expression : proj

          if expression.is_a?(SQL::AST::Star)
            if expression.table
              prefix = "#{expression.table}."
              row.each do |key, value|
                key = key.to_s
                next unless key.start_with?(prefix)

                column = key.delete_prefix(prefix)
                result[column] = value unless column.start_with?("_")
              end
            else
              row.each do |key, value|
                key = key.to_s
                result[key] = value unless key.include?(".") || key.start_with?("_")
              end
            end
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

      def aggregate_rows(rows, group_by, projections)
        groups = {}
        if group_by.empty?
          groups[[]] = rows
        else
          rows.each do |row|
            key = group_by.map { |expression| evaluate_expression(expression, row) }
            (groups[key] ||= []) << row
          end
        end

        groups.map do |_key, group|
          representative = group.first || {}
          projections.each_with_object({}) do |projection, result|
            expression = projection.respond_to?(:expression) ? projection.expression : projection
            name = projection_name(projection)
            result[name] = if aggregate_function?(expression)
              apply_aggregate_function(expression, group)
            else
              evaluate_expression(expression, representative)
            end
          end
        end
      end

      def aggregate_function?(expression)
        expression.is_a?(SQL::AST::FunctionCall) && !expression.window &&
          %w[COUNT SUM AVG MIN MAX].include?(expression.name.to_s.upcase)
      end

      def apply_window_functions!(rows, projections)
        projections.each do |projection|
          expression = projection.respond_to?(:expression) ? projection.expression : projection
          next unless expression.is_a?(SQL::AST::FunctionCall) && expression.window

          spec = expression.window
          partitions = {}
          rows.each { |row| (partitions[spec[:partition_by].map { |part| evaluate_expression(part, row) }] ||= []) << row }
          partitions.each_value do |partition_rows|
            ordered_rows = sort_window_rows(partition_rows, spec[:order_by])
            ordered_rows.each_with_index do |row, index|
              row[window_key(expression)] = window_value(expression, ordered_rows, index, spec[:order_by], spec[:frame])
            end
          end
        end
      end

      def window_key(expression)
        "__rubydb_window_#{expression.object_id}"
      end

      def sort_window_rows(rows, order_by)
        return rows.dup if order_by.empty?

        rows.sort do |left, right|
          comparison = 0
          order_by.each do |item|
            left_value = evaluate_expression(item.expression, left)
            right_value = evaluate_expression(item.expression, right)
            comparison = compare_sort_values(left_value, right_value)
            comparison = -comparison if item.direction == :desc
            break unless comparison.zero?
          end
          comparison
        end
      end

      def compare_sort_values(left, right)
        return 0 if left.nil? && right.nil?
        return -1 if left.nil?
        return 1 if right.nil?

        left <=> right
      end

      def window_value(expression, rows, index, order_by, frame = nil)
        rows = window_frame_rows(rows, index, frame) if frame
        name = expression.name.to_s.upcase
        if %w[ROW_NUMBER RANK DENSE_RANK].include?(name)
          return index + 1 if name == "ROW_NUMBER" || order_by.empty?

          keys = rows.map { |row| order_by.map { |item| evaluate_expression(item.expression, row) } }
          current = keys[index]
          return keys.index(current) + 1 if name == "RANK"

          return keys[0..index].uniq.index(current) + 1
        end

        argument = expression.arguments.first
        values = if argument.is_a?(SQL::AST::Star)
          rows
        else
          rows.map { |row| evaluate_expression(argument, row) }.compact
        end
        values = values.uniq if expression.distinct
        case name
        when "COUNT" then values.size
        when "SUM" then values.empty? ? nil : values.sum
        when "AVG" then values.empty? ? nil : values.sum / values.size.to_f
        when "MIN" then values.min
        when "MAX" then values.max
        else
          raise ExecutionError, "Unsupported window function: #{expression.name}"
        end
      end

      def window_frame_rows(rows, index, frame)
        start_index = window_frame_index(frame[:start], index, rows.size, start: true)
        finish = frame[:finish] || {kind: :current_row}
        end_index = window_frame_index(finish, index, rows.size, start: false)
        return [] if start_index > end_index

        rows[start_index..end_index] || []
      end

      def window_frame_index(boundary, index, size, start:)
        case boundary[:kind]
        when :unbounded_preceding then 0
        when :unbounded_following then size - 1
        when :current_row then index
        when :preceding then [index - boundary[:value], 0].max
        when :following then [index + boundary[:value], size - 1].min
        else raise ExecutionError, "Unsupported window frame boundary: #{boundary[:kind]}"
        end
      end

      def apply_aggregate_function(expression, rows)
        argument = expression.arguments.first
        values = if argument.is_a?(SQL::AST::Star)
          rows
        else
          rows.map { |row| evaluate_expression(argument, row) }.compact
        end
        values = values.uniq if expression.distinct

        case expression.name.to_s.upcase
        when "COUNT" then values.size
        when "SUM" then values.empty? ? nil : values.sum
        when "AVG" then values.empty? ? nil : values.sum / values.size.to_f
        when "MIN" then values.min
        when "MAX" then values.max
        end
      end

      def apply_aggregate(agg, rows)
        values = rows.map { |row| row[agg.column.to_s] }.compact

        case agg.name.to_s.upcase
        when "COUNT" then values.size
        when "SUM" then values.sum
        when "AVG" then values.empty? ? 0 : values.sum / values.size.to_f
        when "MIN" then values.min
        when "MAX" then values.max
        end
      end

      def sort_rows(rows, order_by)
        rows.sort do |a, b|
          comparison = 0
          order_by.each do |order|
            col = (order.is_a?(Hash) ? order[:column] : order.column).to_s
            val_a = order_value(a, col)
            val_b = order_value(b, col)

            comparison = if val_a.nil? && val_b.nil?
              0
            elsif val_a.nil?
              -1
            elsif val_b.nil?
              1
            else
              val_a <=> val_b
            end

            direction = order.is_a?(Hash) ? order[:direction] : order.direction
            comparison = -comparison if direction.to_s.casecmp?("desc")
            break unless comparison == 0
          end
          comparison
        end
      end

      def order_value(row, column)
        return row[column] if row.key?(column)
        return row[column.to_sym] if row.key?(column.to_sym)

        short_column = column.split(".").last
        return row[short_column] if row.key?(short_column)
        return row[short_column.to_sym] if row.key?(short_column.to_sym)

        nil
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

        lines << if plan.scan_type == :index
          "Index Scan on #{plan.table_name} using #{plan.index.name}"
        else
          "Seq Scan on #{plan.table_name}"
        end

        if plan.predicate
          lines << "  Filter: #{plan.predicate}"
        end

        if plan.order_by&.any?
          order_str = plan.order_by.map do |order|
            column = order.is_a?(Hash) ? order[:column] : order.column
            direction = order.is_a?(Hash) ? order[:direction] : order.direction
            "#{column} #{direction}"
          end.join(", ")
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
