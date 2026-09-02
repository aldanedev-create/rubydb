# frozen_string_literal: true

module RubyDB
  module SQL
    module Planner
      # Binder - Resolves identifiers and binds AST nodes to catalog objects
      class Binder
        attr_reader :catalog, :errors, :warnings

        def initialize(catalog)
          @catalog = catalog
          @errors = []
          @warnings = []
          @current_scope = {}
          @current_table = nil
          @current_table_alias = nil
          @in_subquery = false
        end

        # Bind an AST statement to catalog objects
        def bind(statement)
          @errors = []
          @warnings = []
          statement.accept(self)
          [statement, @errors, @warnings]
        end

        # --- Visitor methods ---

        def visit_select(node)
          # Bind FROM clause first
          if node.from
            table_info = bind_table_reference(node.from)
            @current_table = table_info
            @current_table_alias = node.from.alias_name || node.from.name

            # Build scope from table columns
            @current_scope = build_scope_from_table(table_info)
          end

          # Bind WHERE clause
          if node.where
            node.where.accept(self)
          end

          # Bind ORDER BY
          node.order_by.each do |order_item|
            order_item.accept(self)
          end

          # Bind LIMIT and OFFSET
          node.limit&.accept(self)
          node.offset&.accept(self)

          # Bind columns
          node.columns.each do |col|
            col.accept(self)
          end

          # Clear scope after binding
          @current_scope = {}
          @current_table = nil
          @current_table_alias = nil
        end

        def visit_insert(node)
          table_info = @catalog.find_table(node.table)
          unless table_info
            @errors << "Table '#{node.table}' does not exist"
            return
          end

          @current_table = table_info
          @current_table_alias = node.table
          @current_scope = build_scope_from_table(table_info)

          # Validate columns
          if node.columns.any?
            node.columns.each do |col_name|
              unless table_info.columns.any? { |c| c.name == col_name }
                @errors << "Column '#{col_name}' does not exist in table '#{node.table}'"
              end
            end
          end

          # Bind values
          node.values.each do |value|
            value.accept(self)
          end

          @current_scope = {}
          @current_table = nil
          @current_table_alias = nil
        end

        def visit_update(node)
          table_info = @catalog.find_table(node.table)
          unless table_info
            @errors << "Table '#{node.table}' does not exist"
            return
          end

          @current_table = table_info
          @current_table_alias = node.table
          @current_scope = build_scope_from_table(table_info)

          # Validate assignments
          node.assignments.each do |assignment|
            unless table_info.columns.any? { |c| c.name == assignment.column }
              @errors << "Column '#{assignment.column}' does not exist in table '#{node.table}'"
            end
            assignment.value.accept(self)
          end

          # Bind WHERE clause
          if node.where
            node.where.accept(self)
          end

          @current_scope = {}
          @current_table = nil
          @current_table_alias = nil
        end

        def visit_delete(node)
          table_info = @catalog.find_table(node.table)
          unless table_info
            @errors << "Table '#{node.table}' does not exist"
            return
          end

          @current_table = table_info
          @current_table_alias = node.table
          @current_scope = build_scope_from_table(table_info)

          # Bind WHERE clause
          if node.where
            node.where.accept(self)
          end

          @current_scope = {}
          @current_table = nil
          @current_table_alias = nil
        end

        def visit_create_table(node)
          # Check if table already exists
          if @catalog.find_table(node.name)
            unless node.if_not_exists
              @errors << "Table '#{node.name}' already exists"
            end
            return
          end

          # Validate column definitions
          node.columns.each do |col|
            # Check for duplicate column names
            if node.columns.count { |c| c.name == col.name } > 1
              @errors << "Duplicate column name '#{col.name}' in table '#{node.name}'"
            end

            # Validate type
            type_class = col.type_class
            unless valid_type?(type_class)
              @errors << "Invalid data type '#{type_class}' for column '#{col.name}'"
            end
          end

          # Validate constraints
          node.constraints.each do |constraint|
            constraint.accept(self)
          end
        end

        def visit_alter_table_add_column(node)
          table_info = @catalog.find_table(node.table_name)
          unless table_info
            @errors << "Table '#{node.table_name}' does not exist"
            return
          end

          # Check if column already exists
          if table_info.columns.any? { |c| c.name == node.column_name }
            @errors << "Column '#{node.column_name}' already exists in table '#{node.table_name}'"
          end

          # Validate type
          type_class = node.column_type.is_a?(Hash) ? node.column_type[:type] : node.column_type
          unless valid_type?(type_class)
            @errors << "Invalid data type '#{type_class}' for column '#{node.column_name}'"
          end
        end

        def visit_alter_table_drop_column(node)
          table_info = @catalog.find_table(node.table_name)
          unless table_info
            @errors << "Table '#{node.table_name}' does not exist"
            return
          end

          unless table_info.columns.any? { |c| c.name == node.column_name }
            @errors << "Column '#{node.column_name}' does not exist in table '#{node.table_name}'"
          end
        end

        def visit_alter_table_add_constraint(node)
          table_info = @catalog.find_table(node.table_name)
          unless table_info
            @errors << "Table '#{node.table_name}' does not exist"
            return
          end
          @current_table = table_info
          node.constraint.accept(self)
          @current_table = nil
        end

        def visit_alter_table_drop_constraint(node)
          table_info = @catalog.find_table(node.table_name)
          unless table_info
            @errors << "Table '#{node.table_name}' does not exist"
            return
          end
          # Constraint metadata is persisted by the storage engine and may not
          # yet be hydrated into the catalog after a restart. The executor is
          # authoritative for the existence check.
        end

        def visit_drop_table(node)
          unless @catalog.find_table(node.name)
            unless node.if_exists
              @errors << "Table '#{node.name}' does not exist"
            end
          end
        end

        def visit_create_index(node)
          table_info = @catalog.find_table(node.table_name)
          unless table_info
            @errors << "Table '#{node.table_name}' does not exist"
            return
          end

          # Validate columns
          node.columns.each do |col_name|
            unless table_info.columns.any? { |c| c.name == col_name }
              @errors << "Column '#{col_name}' does not exist in table '#{node.table_name}'"
            end
          end

          # Check if index already exists
          if table_info.indexes.any? { |idx| idx.name == node.name }
            unless node.if_not_exists
              @errors << "Index '#{node.name}' already exists"
            end
          end
        end

        def visit_drop_index(node)
          # Check if index exists (we need to search all tables)
          index_exists = false
          @catalog.tables.each do |table|
            if table.indexes.any? { |idx| idx.name == node.name }
              index_exists = true
              break
            end
          end

          unless index_exists
            unless node.if_exists
              @errors << "Index '#{node.name}' does not exist"
            end
          end
        end

        def visit_create_database(node)
          if @catalog.find_database(node.name)
            unless node.if_not_exists
              @errors << "Database '#{node.name}' already exists"
            end
          end
        end

        def visit_drop_database(node)
          unless @catalog.find_database(node.name)
            unless node.if_exists
              @errors << "Database '#{node.name}' does not exist"
            end
          end
        end

        def visit_create_schema(node)
          if @catalog.find_schema(node.name)
            @errors << "Schema '#{node.name}' already exists" unless node.if_not_exists
          end
        end

        def visit_drop_schema(node)
          unless @catalog.find_schema(node.name)
            @errors << "Schema '#{node.name}' does not exist" unless node.if_exists
          end
        end

        def visit_create_view(node)
          if @catalog.find_view(node.name)
            @errors << "View '#{node.name}' already exists" unless node.if_not_exists
          end
          node.query.accept(self)
        end

        def visit_drop_view(node)
          if !@catalog.find_view(node.name) && !node.if_exists
            @errors << "View '#{node.name}' does not exist"
          end
        end

        def visit_create_trigger(node)
          unless @catalog.find_table(node.table_name)
            @errors << "Table '#{node.table_name}' does not exist"
          end
          if @catalog.find_trigger(node.name)
            @errors << "Trigger '#{node.name}' already exists"
          end
        end

        def visit_drop_trigger(node)
          if !@catalog.find_trigger(node.name) && !node.if_exists
            @errors << "Trigger '#{node.name}' does not exist"
          end
        end

        # --- Expression visitors ---

        def visit_identifier(node)
          # Check if identifier is in current scope
          if @current_scope.key?(node.name)
            # Resolve to column
            node.table = @current_table_alias if node.table.nil?
            column_info = @current_scope[node.name]
            node.instance_variable_set(:@column_info, column_info)
          else
            @errors << "Column '#{node.name}' does not exist in current scope"
          end
        end

        def visit_binary_op(node)
          node.left.accept(self)
          node.right.accept(self)

          # Type compatibility check
          left_type = get_expression_type(node.left)
          right_type = get_expression_type(node.right)

          if left_type && right_type && !type_compatible?(left_type, right_type, node.operator)
            @warnings << "Type mismatch in binary operation: #{left_type} #{node.operator} #{right_type}"
          end
        end

        def visit_unary_op(node)
          node.operand.accept(self)
        end

        def visit_between(node)
          node.expression.accept(self)
          node.low.accept(self)
          node.high.accept(self)
        end

        def visit_in(node)
          node.expression.accept(self)
          node.values.each(&:accept)
        end

        def visit_is_null(node)
          node.expression.accept(self)
        end

        def visit_function_call(node)
          # Validate function exists
          unless function_exists?(node.name)
            @errors << "Function '#{node.name}' does not exist"
          end

          node.arguments.each(&:accept)
        end

        def visit_parameter(node)
          # Parameters are valid in any context
        end

        def visit_literal(node)
          # Literals are always valid
        end

        def visit_star(node)
          # Star is only valid in SELECT columns
          unless @in_select_columns
            @errors << "Invalid use of '*' outside SELECT column list"
          end
        end

        # --- Constraint visitors ---

        def visit_primary_key_constraint(node)
          table_info = @current_table
          if table_info
            node.columns.each do |col_name|
              unless table_info.columns.any? { |c| c.name == col_name }
                @errors << "Column '#{col_name}' does not exist for PRIMARY KEY constraint"
              end
            end
          end
        end

        def visit_foreign_key_constraint(node)
          table_info = @current_table
          if table_info
            node.columns.each do |col_name|
              unless table_info.columns.any? { |c| c.name == col_name }
                @errors << "Column '#{col_name}' does not exist for FOREIGN KEY constraint"
              end
            end
          end

          # Validate referenced table exists
          unless @catalog.find_table(node.reference_table)
            @errors << "Referenced table '#{node.reference_table}' does not exist"
          end
        end

        def visit_unique_constraint(node)
          table_info = @current_table
          if table_info
            node.columns.each do |col_name|
              unless table_info.columns.any? { |c| c.name == col_name }
                @errors << "Column '#{col_name}' does not exist for UNIQUE constraint"
              end
            end
          end
        end

        def visit_check_constraint(node)
          node.condition.accept(self)
        end

        # --- Helper methods ---

        private

        def bind_table_reference(table_ref)
          table_info = @catalog.find_table(table_ref.name)
          unless table_info
            @errors << "Table '#{table_ref.name}' does not exist"
            return nil
          end
          table_info
        end

        def build_scope_from_table(table_info)
          scope = {}
          if table_info
            table_info.columns.each do |col|
              scope[col.name] = col
            end
          end
          scope
        end

        def get_expression_type(expr)
          return nil unless expr.respond_to?(:type)

          if expr.type
            expr.type
          elsif expr.is_a?(AST::Identifier)
            # Try to resolve from scope
            @current_scope[expr.name]&.type
          elsif expr.is_a?(AST::Literal)
            map_literal_type(expr)
          else
            nil
          end
        end

        def map_literal_type(literal)
          case literal.token_type
          when Token::Type::STRING
            :text
          when Token::Type::NUMBER
            literal.value.is_a?(Integer) ? :integer : :float
          when Token::Type::TRUE, Token::Type::FALSE
            :boolean
          when Token::Type::NULL
            nil
          else
            nil
          end
        end

        def type_compatible?(type1, type2, operator)
          # Numeric types are compatible with each other
          numeric_types = [:integer, :bigint, :smallint, :float, :decimal]
          if numeric_types.include?(type1) && numeric_types.include?(type2)
            return true
          end

          # Text types are compatible with each other
          text_types = [:text, :varchar, :char]
          if text_types.include?(type1) && text_types.include?(type2)
            return true
          end

          # Same type is always compatible
          return true if type1 == type2

          # Comparison operators can handle most types
          if [Token::Type::EQ, Token::Type::NE, Token::Type::LT,
              Token::Type::LTE, Token::Type::GT, Token::Type::GTE].include?(operator)
            return true
          end

          false
        end

        def valid_type?(type)
          # Check if type is registered in type system
          begin
            Types::TypeRegistry.lookup(type)
            true
          rescue ConfigurationError
            false
          end
        end

        def function_exists?(name)
          # Check if function is registered
          # Built-in SQL functions are bound without a catalog entry.
          common_functions = %w[
            COUNT SUM AVG MAX MIN LOWER UPPER LENGTH
            SUBSTR CONCAT COALESCE NULLIF
            DATE TIME TIMESTAMP EXTRACT
            JSON_ARRAY JSON_OBJECT JSON_EXTRACT
          ]
          common_functions.include?(name.upcase)
        end
      end
    end
  end
end
