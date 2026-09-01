# frozen_string_literal: true

module RubyDB
  module SQL
    module AST
      # Base class for all expression nodes
      class Expression < Node
        # Type of expression result (set by type checker)
        attr_accessor :type

        def initialize(location: nil)
          super(location: location)
          @type = nil
        end

        # Is this expression a literal value?
        def literal?
          false
        end

        # Is this expression a column reference?
        def column?
          false
        end

        # Is this expression NULL?
        def null?
          false
        end

        # Does this expression contain a subquery?
        def contains_subquery?
          false
        end
      end

      # Literal value
      class Literal < Expression
        attr_reader :value, :token_type

        def initialize(value, token_type, location: nil)
          super(location: location)
          @value = value
          @token_type = token_type
        end

        def literal?
          true
        end

        def null?
          @value.nil?
        end

        def accept(visitor)
          visitor.visit_literal(self)
        end

        def clone
          Literal.new(@value, @token_type, location: @location)
        end

        def to_sql
          case @token_type
          when Token::Type::STRING
            "'#{@value.to_s.gsub("'", "''")}'"
          when Token::Type::NUMBER
            @value.to_s
          when Token::Type::NULL
            "NULL"
          when Token::Type::TRUE
            "TRUE"
          when Token::Type::FALSE
            "FALSE"
          else
            @value.to_s
          end
        end

        def inspect
          "Literal(#{@value})"
        end
      end

      # NULL literal
      class NullLiteral < Literal
        def initialize(location: nil)
          super(nil, Token::Type::NULL, location: location)
        end

        def null?
          true
        end

        def to_sql
          "NULL"
        end

        def inspect
          "NULL"
        end
      end

      # Column reference
      class Identifier < Expression
        attr_reader :name, :table

        def initialize(name, table: nil, location: nil)
          super(location: location)
          @name = name
          @table = table
        end

        def column?
          true
        end

        def accept(visitor)
          visitor.visit_identifier(self)
        end

        def clone
          Identifier.new(@name, table: @table, location: @location)
        end

        def to_sql
          if @table
            "#{@table}.#{@name}"
          else
            @name
          end
        end

        def inspect
          if @table
            "Identifier(#{@table}.#{@name})"
          else
            "Identifier(#{@name})"
          end
        end
      end

      # Unary operator expression
      class UnaryOp < Expression
        attr_reader :operator, :operand

        def initialize(operator, operand, location: nil)
          super(location: location)
          @operator = operator
          @operand = operand
        end

        def accept(visitor)
          visitor.visit_unary_op(self)
        end

        def clone
          UnaryOp.new(@operator, @operand.clone, location: @location)
        end

        def to_sql
          "#{operator_string(@operator)}#{@operand.to_sql}"
        end

        def inspect
          "UnaryOp(#{@operator}, #{@operand.inspect})"
        end

        private

        def operator_string(op)
          case op
          when Token::Type::PLUS then "+"
          when Token::Type::MINUS then "-"
          when Token::Type::TILDE then "~"
          when Token::Type::NOT then "NOT "
          else op.to_s
          end
        end
      end

      # Binary operator expression
      class BinaryOp < Expression
        attr_reader :operator, :left, :right

        def initialize(operator, left, right, location: nil)
          super(location: location)
          @operator = operator
          @left = left
          @right = right
        end

        def accept(visitor)
          visitor.visit_binary_op(self)
        end

        def clone
          BinaryOp.new(@operator, @left.clone, @right.clone, location: @location)
        end

        def to_sql
          "#{@left.to_sql} #{operator_string(@operator)} #{@right.to_sql}"
        end

        def inspect
          "BinaryOp(#{@operator}, #{@left.inspect}, #{@right.inspect})"
        end

        private

        def operator_string(op)
          case op
          when Token::Type::EQ then "="
          when Token::Type::NE then "!="
          when Token::Type::LT then "<"
          when Token::Type::LTE then "<="
          when Token::Type::GT then ">"
          when Token::Type::GTE then ">="
          when Token::Type::PLUS then "+"
          when Token::Type::MINUS then "-"
          when Token::Type::STAR then "*"
          when Token::Type::SLASH then "/"
          when Token::Type::PERCENT then "%"
          when Token::Type::AND then "AND"
          when Token::Type::OR then "OR"
          when Token::Type::LIKE then "LIKE"
          when Token::Type::ILIKE then "ILIKE"
          else op.to_s
          end
        end
      end

      # BETWEEN expression
      class Between < Expression
        attr_reader :expression, :low, :high

        def initialize(expression, low, high, location: nil)
          super(location: location)
          @expression = expression
          @low = low
          @high = high
        end

        def accept(visitor)
          visitor.visit_between(self)
        end

        def clone
          Between.new(@expression.clone, @low.clone, @high.clone, location: @location)
        end

        def to_sql
          "#{@expression.to_sql} BETWEEN #{@low.to_sql} AND #{@high.to_sql}"
        end

        def inspect
          "Between(#{@expression.inspect}, #{@low.inspect}, #{@high.inspect})"
        end
      end

      # IN expression
      class In < Expression
        attr_reader :expression, :values

        def initialize(expression, values, location: nil)
          super(location: location)
          @expression = expression
          @values = values
        end

        def accept(visitor)
          visitor.visit_in(self)
        end

        def clone
          In.new(@expression.clone, @values.map(&:clone), location: @location)
        end

        def to_sql
          values_sql = @values.map(&:to_sql).join(", ")
          "#{@expression.to_sql} IN (#{values_sql})"
        end

        def inspect
          "In(#{@expression.inspect}, #{@values.map(&:inspect).join(", ")})"
        end
      end

      # IS NULL expression
      class IsNull < Expression
        attr_reader :expression, :negated

        def initialize(expression, negated = false, location: nil)
          super(location: location)
          @expression = expression
          @negated = negated
        end

        def accept(visitor)
          visitor.visit_is_null(self)
        end

        def clone
          IsNull.new(@expression.clone, @negated, location: @location)
        end

        def to_sql
          if @negated
            "#{@expression.to_sql} IS NOT NULL"
          else
            "#{@expression.to_sql} IS NULL"
          end
        end

        def inspect
          if @negated
            "IsNull(#{@expression.inspect}, negated: true)"
          else
            "IsNull(#{@expression.inspect})"
          end
        end
      end

      # Function call
      class FunctionCall < Expression
        attr_reader :name, :arguments

        def initialize(name, arguments = [], location: nil)
          super(location: location)
          @name = name
          @arguments = arguments
        end

        def accept(visitor)
          visitor.visit_function_call(self)
        end

        def clone
          FunctionCall.new(@name, @arguments.map(&:clone), location: @location)
        end

        def to_sql
          args = @arguments.map(&:to_sql).join(", ")
          "#{@name}(#{args})"
        end

        def inspect
          "FunctionCall(#{@name}, #{@arguments.map(&:inspect).join(", ")})"
        end
      end

      # Parameter (placeholder) for prepared statements
      class Parameter < Expression
        attr_reader :index

        def initialize(index = nil, location: nil)
          super(location: location)
          @index = index
        end

        def accept(visitor)
          visitor.visit_parameter(self)
        end

        def clone
          Parameter.new(@index, location: @location)
        end

        def to_sql
          if @index
            "$#{@index}"
          else
            "?"
          end
        end

        def inspect
          if @index
            "Parameter($#{@index})"
          else
            "Parameter(?)"
          end
        end
      end

      # Star (*) in SELECT
      class Star < Expression
        def initialize(location: nil)
          super(location: location)
        end

        def accept(visitor)
          visitor.visit_star(self)
        end

        def clone
          Star.new(location: @location)
        end

        def to_sql
          "*"
        end

        def inspect
          "Star"
        end
      end

      # SELECT column with optional alias
      class SelectColumn < Node
        attr_reader :expression, :alias_name

        def initialize(expression, alias_name = nil, location: nil)
          super(location: location)
          @expression = expression
          @alias_name = alias_name
        end

        def accept(visitor)
          visitor.visit_select_column(self)
        end

        def clone
          SelectColumn.new(@expression.clone, @alias_name, location: @location)
        end

        def to_sql
          if @alias_name
            "#{@expression.to_sql} AS #{@alias_name}"
          else
            @expression.to_sql
          end
        end

        def inspect
          if @alias_name
            "SelectColumn(#{@expression.inspect}, AS #{@alias_name})"
          else
            "SelectColumn(#{@expression.inspect})"
          end
        end
      end

      # Table reference with optional alias
      class TableRef < Node
        attr_reader :name, :alias_name

        def initialize(name, alias_name = nil, location: nil)
          super(location: location)
          @name = name
          @alias_name = alias_name
        end

        def accept(visitor)
          visitor.visit_table_ref(self)
        end

        def clone
          TableRef.new(@name, @alias_name, location: @location)
        end

        def to_sql
          if @alias_name
            "#{@name} AS #{@alias_name}"
          else
            @name
          end
        end

        def inspect
          if @alias_name
            "TableRef(#{@name} AS #{@alias_name})"
          else
            "TableRef(#{@name})"
          end
        end
      end

      # ORDER BY item
      class OrderItem < Node
        attr_reader :expression, :direction

        def initialize(expression, direction = :asc, location: nil)
          super(location: location)
          @expression = expression
          @direction = direction
        end

        def accept(visitor)
          visitor.visit_order_item(self)
        end

        def clone
          OrderItem.new(@expression.clone, @direction, location: @location)
        end

        def to_sql
          dir = @direction == :asc ? "ASC" : "DESC"
          "#{@expression.to_sql} #{dir}"
        end

        def inspect
          "OrderItem(#{@expression.inspect}, #{@direction})"
        end
      end
    end
  end
end