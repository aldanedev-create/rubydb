# frozen_string_literal: true

module RubyDB
  module SQL
    module Planner
      # Analyzer - Performs semantic analysis and query rewriting
      class Analyzer
        attr_reader :errors, :warnings

        def initialize(catalog)
          @catalog = catalog
          @errors = []
          @warnings = []
          @binder = Binder.new(catalog)
          @type_checker = TypeChecker.new(catalog)
        end

        # Analyze a statement
        def analyze(statement)
          @errors = []
          @warnings = []

          # First pass: Bind identifiers
          bound_statement, bind_errors, bind_warnings = @binder.bind(statement)
          @errors.concat(bind_errors)
          @warnings.concat(bind_warnings)

          # Second pass: Type checking
          typed_statement, type_errors, type_warnings = @type_checker.check(bound_statement)
          @errors.concat(type_errors)
          @warnings.concat(type_warnings)

          # Third pass: Query rewriting (if no errors)
          if @errors.empty?
            rewritten_statement = rewrite(typed_statement)
            return [rewritten_statement, @errors, @warnings]
          end

          [typed_statement, @errors, @warnings]
        end

        # Perform query rewriting
        def rewrite(statement)
          # Rewrite '*' to explicit columns
          if statement.is_a?(AST::Select) && statement.has_star?
            statement = expand_star(statement)
          end

          # Normalize expressions
          statement = normalize_expressions(statement)

          # Remove redundant conditions
          statement = simplify_conditions(statement)

          statement
        end

        private

        def expand_star(select)
          table_info = @catalog.find_table(select.table_name)
          return select unless table_info

          # Replace star with all columns
          new_columns = table_info.columns.map do |col|
            expr = AST::Identifier.new(col.name, table: select.table_name)
            AST::SelectColumn.new(expr)
          end

          # Keep non-star columns
          non_star_columns = select.columns.reject { |c| c.expression.is_a?(AST::Star) }

          AST::Select.new(
            new_columns + non_star_columns,
            select.from,
            select.where,
            select.order_by,
            select.limit,
            select.offset,
            select.distinct
          )
        end

        def normalize_expressions(node)
          # Recursively normalize expression trees
          case node
          when AST::BinaryOp
            # Simplify constant expressions
            if node.left.is_a?(AST::Literal) && node.right.is_a?(AST::Literal)
              return evaluate_constant_expression(node)
            end
            node.left = normalize_expressions(node.left)
            node.right = normalize_expressions(node.right)
            node

          when AST::UnaryOp
            # Simplify constant unary expressions
            if node.operand.is_a?(AST::Literal)
              return evaluate_constant_unary(node)
            end
            node.operand = normalize_expressions(node.operand)
            node

          when AST::Between
            node.expression = normalize_expressions(node.expression)
            node.low = normalize_expressions(node.low)
            node.high = normalize_expressions(node.high)
            node

          when AST::In
            node.expression = normalize_expressions(node.expression)
            node.values = node.values.map { |v| normalize_expressions(v) }
            node

          when AST::IsNull
            node.expression = normalize_expressions(node.expression)
            node

          when AST::Select
            if node.where
              node.where = normalize_expressions(node.where)
            end
            if node.limit
              node.limit = normalize_expressions(node.limit)
            end
            if node.offset
              node.offset = normalize_expressions(node.offset)
            end
            node.order_by.each do |order_item|
              order_item.expression = normalize_expressions(order_item.expression)
            end
            node

          when AST::Insert
            node.values = node.values.map { |v| normalize_expressions(v) }
            node

          when AST::Update
            node.assignments.each do |assignment|
              assignment.value = normalize_expressions(assignment.value)
            end
            if node.where
              node.where = normalize_expressions(node.where)
            end
            node

          when AST::Delete
            if node.where
              node.where = normalize_expressions(node.where)
            end
            node

          else
            node
          end
        end

        def evaluate_constant_expression(expr)
          left_val = expr.left.value
          right_val = expr.right.value

          result = case expr.operator
          when Token::Type::PLUS
            left_val + right_val
          when Token::Type::MINUS
            left_val - right_val
          when Token::Type::STAR
            left_val * right_val
          when Token::Type::SLASH
            left_val / right_val if right_val != 0
          when Token::Type::PERCENT
            left_val % right_val if right_val != 0
          when Token::Type::EQ
            left_val == right_val
          when Token::Type::NE
            left_val != right_val
          when Token::Type::LT
            left_val < right_val
          when Token::Type::LTE
            left_val <= right_val
          when Token::Type::GT
            left_val > right_val
          when Token::Type::GTE
            left_val >= right_val
          else
            return expr
          end

          if result.nil?
            return AST::NullLiteral.new
          end

          token_type = result.is_a?(Integer) ? Token::Type::NUMBER : Token::Type::NUMBER
          AST::Literal.new(result, token_type)
        end

        def evaluate_constant_unary(expr)
          val = expr.operand.value

          result = case expr.operator
          when Token::Type::MINUS
            -val
          when Token::Type::PLUS
            +val
          when Token::Type::TILDE
            ~val if val.is_a?(Integer)
          else
            return expr
          end

          if result.nil?
            return AST::NullLiteral.new
          end

          token_type = result.is_a?(Integer) ? Token::Type::NUMBER : Token::Type::NUMBER
          AST::Literal.new(result, token_type)
        end

        def simplify_conditions(node)
          # Simplify WHERE conditions
          case node
          when AST::Select
            if node.where
              node.where = simplify_condition(node.where)
            end
            node

          when AST::Update
            if node.where
              node.where = simplify_condition(node.where)
            end
            node

          when AST::Delete
            if node.where
              node.where = simplify_condition(node.where)
            end
            node

          else
            node
          end
        end

        def simplify_condition(condition)
          case condition
          when AST::BinaryOp
            # Simplify AND/OR trees
            if condition.operator == Token::Type::AND
              left = simplify_condition(condition.left)
              right = simplify_condition(condition.right)

              # TRUE AND X => X
              if left.is_a?(AST::Literal) && left.value == true
                return right
              end
              # X AND TRUE => X
              if right.is_a?(AST::Literal) && right.value == true
                return left
              end
              # FALSE AND X => FALSE
              if left.is_a?(AST::Literal) && left.value == false
                return left
              end
              # X AND FALSE => FALSE
              if right.is_a?(AST::Literal) && right.value == false
                return right
              end
            end

            if condition.operator == Token::Type::OR
              left = simplify_condition(condition.left)
              right = simplify_condition(condition.right)

              # TRUE OR X => TRUE
              if left.is_a?(AST::Literal) && left.value == true
                return left
              end
              # X OR TRUE => TRUE
              if right.is_a?(AST::Literal) && right.value == true
                return right
              end
              # FALSE OR X => X
              if left.is_a?(AST::Literal) && left.value == false
                return right
              end
              # X OR FALSE => X
              if right.is_a?(AST::Literal) && right.value == false
                return left
              end
            end

            condition

          else
            condition
          end
        end
      end
    end
  end
end