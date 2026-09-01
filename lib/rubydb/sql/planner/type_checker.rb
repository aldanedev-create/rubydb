# frozen_string_literal: true

module RubyDB
  module SQL
    module Planner
      # TypeChecker - Validates type compatibility and infers expression types
      class TypeChecker
        attr_reader :errors, :warnings

        def initialize(catalog)
          @catalog = catalog
          @errors = []
          @warnings = []
          @current_scope = {}
          @current_table = nil
        end

        # Type check a statement
        def check(statement)
          @errors = []
          @warnings = []
          statement.accept(self)
          [statement, @errors, @warnings]
        end

        # --- Visitor methods ---

        def visit_select(node)
          # Build scope from FROM clause
          if node.from
            table_info = @catalog.find_table(node.from.name)
            if table_info
              @current_table = table_info
              @current_scope = {}
              table_info.columns.each do |col|
                @current_scope[col.name] = col
              end
            end
          end

          # Check WHERE clause
          if node.where
            where_type = type_check_expression(node.where)
            unless where_type == :boolean || where_type.nil?
              @warnings << "WHERE clause should be boolean, got #{where_type}"
            end
          end

          # Check columns
          node.columns.each do |col|
            if col.expression.is_a?(AST::Star)
              # Star is always valid
              next
            end
            type_check_expression(col.expression)
          end

          # Check ORDER BY
          node.order_by.each do |order_item|
            type_check_expression(order_item.expression)
          end

          # Check LIMIT and OFFSET
          if node.limit
            limit_type = type_check_expression(node.limit)
            unless limit_type == :integer || limit_type.nil?
              @warnings << "LIMIT should be integer, got #{limit_type}"
            end
          end

          if node.offset
            offset_type = type_check_expression(node.offset)
            unless offset_type == :integer || offset_type.nil?
              @warnings << "OFFSET should be integer, got #{offset_type}"
            end
          end

          @current_scope = {}
          @current_table = nil
        end

        def visit_insert(node)
          table_info = @catalog.find_table(node.table)
          if table_info
            @current_table = table_info
            @current_scope = {}
            table_info.columns.each do |col|
              @current_scope[col.name] = col
            end
          end

          # Type check values
          node.values.each do |value|
            type_check_expression(value)
          end

          @current_scope = {}
          @current_table = nil
        end

        def visit_update(node)
          table_info = @catalog.find_table(node.table)
          if table_info
            @current_table = table_info
            @current_scope = {}
            table_info.columns.each do |col|
              @current_scope[col.name] = col
            end
          end

          # Type check assignments
          node.assignments.each do |assignment|
            value_type = type_check_expression(assignment.value)

            # Check if value type matches column type
            if @current_scope.key?(assignment.column)
              column = @current_scope[assignment.column]
              col_type = column.type.to_sym
              if value_type && !type_compatible?(value_type, col_type)
                @warnings << "Type mismatch: column '#{assignment.column}' expects #{col_type}, got #{value_type}"
              end
            end
          end

          # Check WHERE clause
          if node.where
            where_type = type_check_expression(node.where)
            unless where_type == :boolean || where_type.nil?
              @warnings << "WHERE clause should be boolean, got #{where_type}"
            end
          end

          @current_scope = {}
          @current_table = nil
        end

        def visit_delete(node)
          table_info = @catalog.find_table(node.table)
          if table_info
            @current_table = table_info
            @current_scope = {}
            table_info.columns.each do |col|
              @current_scope[col.name] = col
            end
          end

          # Check WHERE clause
          if node.where
            where_type = type_check_expression(node.where)
            unless where_type == :boolean || where_type.nil?
              @warnings << "WHERE clause should be boolean, got #{where_type}"
            end
          end

          @current_scope = {}
          @current_table = nil
        end

        def visit_create_table(node)
          # Validate column types
          node.columns.each do |col|
            type_class = col.type_class
            begin
              Types::TypeRegistry.lookup(type_class)
            rescue ConfigurationError
              @errors << "Unknown data type '#{type_class}' for column '#{col.name}'"
            end
          end

          # Validate constraints
          node.constraints.each do |constraint|
            constraint.accept(self)
          end
        end

        # --- Expression type checking ---

        def type_check_expression(expr)
          case expr
          when AST::BinaryOp
            type_check_binary_op(expr)
          when AST::UnaryOp
            type_check_unary_op(expr)
          when AST::Identifier
            type_check_identifier(expr)
          when AST::Literal
            type_check_literal(expr)
          when AST::Between
            type_check_between(expr)
          when AST::In
            type_check_in(expr)
          when AST::IsNull
            type_check_is_null(expr)
          when AST::FunctionCall
            type_check_function_call(expr)
          when AST::Parameter
            # Parameters can be any type
            nil
          when AST::Star
            # Star has no type
            nil
          else
            nil
          end
        end

        def type_check_binary_op(expr)
          left_type = type_check_expression(expr.left)
          right_type = type_check_expression(expr.right)

          # Determine result type
          case expr.operator
          when Token::Type::EQ, Token::Type::NE,
               Token::Type::LT, Token::Type::LTE,
               Token::Type::GT, Token::Type::GTE,
               Token::Type::LIKE, Token::Type::ILIKE,
               Token::Type::IN
            # Comparison operators return boolean
            expr.type = :boolean
            return :boolean

          when Token::Type::AND, Token::Type::OR
            # Logical operators require boolean operands
            if left_type && left_type != :boolean
              @warnings << "AND requires boolean left operand, got #{left_type}"
            end
            if right_type && right_type != :boolean
              @warnings << "AND requires boolean right operand, got #{right_type}"
            end
            expr.type = :boolean
            return :boolean

          when Token::Type::PLUS, Token::Type::MINUS,
               Token::Type::STAR, Token::Type::SLASH,
               Token::Type::PERCENT
            # Arithmetic operators require numeric operands
            numeric_types = [:integer, :bigint, :smallint, :float, :decimal]
            unless left_type.nil? || numeric_types.include?(left_type)
              @warnings << "Arithmetic requires numeric left operand, got #{left_type}"
            end
            unless right_type.nil? || numeric_types.include?(right_type)
              @warnings << "Arithmetic requires numeric right operand, got #{right_type}"
            end

            # Result type is numeric
            result_type = left_type || right_type || :integer
            expr.type = result_type
            return result_type

          else
            expr.type = nil
            return nil
          end
        end

        def type_check_unary_op(expr)
          operand_type = type_check_expression(expr.operand)

          case expr.operator
          when Token::Type::NOT
            if operand_type && operand_type != :boolean
              @warnings << "NOT requires boolean operand, got #{operand_type}"
            end
            expr.type = :boolean
            return :boolean

          when Token::Type::PLUS, Token::Type::MINUS, Token::Type::TILDE
            numeric_types = [:integer, :bigint, :smallint, :float, :decimal]
            unless operand_type.nil? || numeric_types.include?(operand_type)
              @warnings << "Unary #{expr.operator} requires numeric operand, got #{operand_type}"
            end
            expr.type = operand_type || :integer
            return expr.type

          else
            expr.type = nil
            return nil
          end
        end

        def type_check_identifier(expr)
          # Look up column in current scope
          if @current_scope.key?(expr.name)
            column = @current_scope[expr.name]
            expr.type = column.type.to_sym
            return expr.type
          end

          # Not found
          @errors << "Column '#{expr.name}' not found in current scope"
          expr.type = nil
          nil
        end

        def type_check_literal(expr)
          case expr.token_type
          when Token::Type::STRING
            expr.type = :text
            :text
          when Token::Type::NUMBER
            if expr.value.is_a?(Integer)
              expr.type = :integer
              :integer
            else
              expr.type = :float
              :float
            end
          when Token::Type::TRUE, Token::Type::FALSE
            expr.type = :boolean
            :boolean
          when Token::Type::NULL
            expr.type = nil
            nil
          else
            expr.type = nil
            nil
          end
        end

        def type_check_between(expr)
          expr_type = type_check_expression(expr.expression)
          low_type = type_check_expression(expr.low)
          high_type = type_check_expression(expr.high)

          # BETWEEN returns boolean
          expr.type = :boolean
          :boolean
        end

        def type_check_in(expr)
          expr_type = type_check_expression(expr.expression)

          # Check all values
          expr.values.each do |value|
            type_check_expression(value)
          end

          # IN returns boolean
          expr.type = :boolean
          :boolean
        end

        def type_check_is_null(expr)
          type_check_expression(expr.expression)

          # IS NULL returns boolean
          expr.type = :boolean
          :boolean
        end

        def type_check_function_call(expr)
          # Check arguments
          expr.arguments.each do |arg|
            type_check_expression(arg)
          end

          # Determine function return type
          return_type = function_return_type(expr.name)
          expr.type = return_type
          return_type
        end

        # --- Constraint type checking ---

        def visit_primary_key_constraint(node)
          # Validate columns exist (done in binder)
        end

        def visit_foreign_key_constraint(node)
          # Validate columns exist (done in binder)
        end

        def visit_unique_constraint(node)
          # Validate columns exist (done in binder)
        end

        def visit_check_constraint(node)
          condition_type = type_check_expression(node.condition)
          unless condition_type == :boolean || condition_type.nil?
            @warnings << "CHECK constraint condition should be boolean, got #{condition_type}"
          end
        end

        # --- Helper methods ---

        private

        def type_compatible?(type1, type2)
          # Same type is always compatible
          return true if type1 == type2

          # Numeric types are compatible
          numeric_types = [:integer, :bigint, :smallint, :float, :decimal]
          if numeric_types.include?(type1) && numeric_types.include?(type2)
            return true
          end

          # Text types are compatible
          text_types = [:text, :varchar, :char]
          if text_types.include?(type1) && text_types.include?(type2)
            return true
          end

          false
        end

        def function_return_type(name)
          # Define return types for common functions
          case name.upcase
          when "COUNT", "SUM", "AVG", "MAX", "MIN"
            :integer
          when "LOWER", "UPPER", "SUBSTR", "CONCAT", "COALESCE", "NULLIF"
            :text
          when "LENGTH"
            :integer
          when "DATE", "TIME", "TIMESTAMP"
            :timestamp
          when "EXTRACT"
            :integer
          when "JSON_ARRAY", "JSON_OBJECT", "JSON_EXTRACT"
            :json
          else
            nil
          end
        end
      end
    end
  end
end