# frozen_string_literal: true

module RubyDB
  module Execution
    # Plan - Query execution plan
    class Plan
      attr_reader :type, :table_name, :columns, :projections, :predicate,
                  :order_by, :group_by, :aggregates, :limit, :offset,
                  :distinct, :scan_type, :index, :estimated_cost,
                  :estimated_rows

      def initialize(type, table_name = nil, columns = [])
        @type = type
        @table_name = table_name
        @columns = columns
        @projections = nil
        @predicate = nil
        @order_by = []
        @group_by = []
        @aggregates = []
        @limit = nil
        @offset = nil
        @distinct = false
        @scan_type = :sequential
        @index = nil
        @estimated_cost = 0
        @estimated_rows = 0
      end

      def set_projections(projections)
        @projections = projections
        self
      end

      def set_predicate(predicate)
        @predicate = predicate
        self
      end

      def set_order_by(order_by)
        @order_by = order_by
        self
      end

      def set_group_by(group_by, aggregates = [])
        @group_by = group_by
        @aggregates = aggregates
        self
      end

      def set_limit(limit, offset = nil)
        @limit = limit
        @offset = offset if offset
        self
      end

      def set_distinct(distinct = true)
        @distinct = distinct
        self
      end

      def set_scan_type(scan_type, index = nil)
        @scan_type = scan_type
        @index = index
        self
      end

      def set_cost(estimated_cost, estimated_rows = nil)
        @estimated_cost = estimated_cost
        @estimated_rows = estimated_rows if estimated_rows
        self
      end

      def to_s
        "Plan(#{@type}) on #{@table_name}"
      end

      def inspect
        to_s
      end

      # Plan types
      class Select < Plan
        def initialize(table_name, columns = [])
          super(:select, table_name, columns)
        end
      end

      class Insert < Plan
        attr_reader :values

        def initialize(table_name, columns = [], values = [])
          super(:insert, table_name, columns)
          @values = values
        end
      end

      class Update < Plan
        attr_reader :assignments

        def initialize(table_name, assignments = [])
          super(:update, table_name)
          @assignments = assignments
        end
      end

      class Delete < Plan
        def initialize(table_name)
          super(:delete, table_name)
        end
      end

      class CreateTable < Plan
        attr_reader :options

        def initialize(table_name, columns = [], options = {})
          super(:create_table, table_name, columns)
          @options = options
        end
      end

      class DropTable < Plan
        attr_reader :options

        def initialize(table_name, options = {})
          super(:drop_table, table_name)
          @options = options
        end
      end

      class CreateDatabase < Plan
        attr_reader :options
        def initialize(name, options = {})
          super(:create_database)
          @database_name = name
          @options = options
        end
        def database_name = @database_name
      end

      class DropDatabase < Plan
        attr_reader :options
        def initialize(name, options = {})
          super(:drop_database)
          @database_name = name
          @options = options
        end
        def database_name = @database_name
      end

      class CreateSchema < Plan
        attr_reader :schema_name, :options
        def initialize(name, options = {})
          super(:create_schema)
          @schema_name = name
          @options = options
        end
      end

      class DropSchema < Plan
        attr_reader :schema_name, :options
        def initialize(name, options = {})
          super(:drop_schema)
          @schema_name = name
          @options = options
        end
      end

      class CreateView < Plan
        attr_reader :view_name, :query, :options
        def initialize(name, query, options = {})
          super(:create_view)
          @view_name = name
          @query = query
          @options = options
        end
      end

      class DropView < Plan
        attr_reader :view_name, :options
        def initialize(name, options = {})
          super(:drop_view)
          @view_name = name
          @options = options
        end
      end

      class CreateTrigger < Plan
        attr_reader :trigger_name, :timing, :event, :target_table, :function_name
        def initialize(name, timing, event, table, function_name)
          super(:create_trigger)
          @trigger_name, @timing, @event, @target_table, @function_name = name, timing, event, table, function_name
        end
      end

      class DropTrigger < Plan
        attr_reader :trigger_name, :options
        def initialize(name, options = {})
          super(:drop_trigger)
          @trigger_name, @options = name, options
        end
      end

      class Vacuum < Plan
        def initialize
          super(:vacuum)
        end
      end

      class AlterTableAddColumn < Plan
        attr_reader :column_name, :column_type, :options

        def initialize(table_name, column_name, column_type, options = {})
          super(:alter_table_add_column, table_name)
          @column_name = column_name
          @column_type = column_type
          @options = options
        end
      end

      class AlterTableDropColumn < Plan
        attr_reader :column_name

        def initialize(table_name, column_name)
          super(:alter_table_drop_column, table_name)
          @column_name = column_name
        end
      end

      class AlterTableAddConstraint < Plan
        attr_reader :constraint
        def initialize(table_name, constraint)
          super(:alter_table_add_constraint, table_name)
          @constraint = constraint
        end
      end

      class AlterTableDropConstraint < Plan
        attr_reader :constraint_name
        def initialize(table_name, constraint_name)
          super(:alter_table_drop_constraint, table_name)
          @constraint_name = constraint_name
        end
      end

      class CreateIndex < Plan
        attr_reader :index_name, :options

        def initialize(index_name, table_name, columns = [], options = {})
          super(:create_index, table_name, columns)
          @index_name = index_name
          @options = options
        end
      end

      class DropIndex < Plan
        attr_reader :index_name, :options

        def initialize(index_name, options = {})
          super(:drop_index)
          @index_name = index_name
          @options = options
        end
      end

      class BeginTransaction < Plan
        attr_reader :isolation_level

        def initialize(isolation_level = :read_committed)
          super(:begin_transaction)
          @isolation_level = isolation_level
        end
      end

      class Commit < Plan
        def initialize
          super(:commit)
        end
      end

      class Rollback < Plan
        def initialize
          super(:rollback)
        end
      end

      class Savepoint < Plan
        attr_reader :name
        def initialize(name)
          super(:savepoint)
          @name = name
        end
      end

      class RollbackToSavepoint < Plan
        attr_reader :name
        def initialize(name)
          super(:rollback_to_savepoint)
          @name = name
        end
      end

      class ReleaseSavepoint < Plan
        attr_reader :name
        def initialize(name)
          super(:release_savepoint)
          @name = name
        end
      end

      class Explain < Plan
        attr_reader :statement, :analyze

        def initialize(statement, analyze = false)
          super(:explain)
          @statement = statement
          @analyze = analyze
        end
      end
    end
  end
end
