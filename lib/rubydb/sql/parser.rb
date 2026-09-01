# frozen_string_literal: true

module RubyDB
  module SQL
    # SQL Parser - converts tokens into AST
    class Parser
      attr_reader :tokens, :position, :current_token

      def initialize(tokens)
        @tokens = tokens
        @position = 0
        @current_token = @tokens[0]
      end

      def parse
        statements = []
        while current_token && current_token.type != Token::Type::EOF
          stmt = parse_statement
          statements << stmt if stmt
          # Skip semicolons between statements
          while current_token && current_token.type == Token::Type::SEMICOLON
            advance
          end
        end
        statements
      end

      private

      def parse_statement
        case current_token&.type
        when Token::Type::SELECT
          parse_select
        when Token::Type::INSERT
          parse_insert
        when Token::Type::UPDATE
          parse_update
        when Token::Type::DELETE
          parse_delete
        when Token::Type::CREATE
          parse_create
        when Token::Type::DROP
          parse_drop
        when Token::Type::ALTER
          parse_alter
        when Token::Type::BEGIN_TRANSACTION
          parse_begin
        when Token::Type::COMMIT
          parse_commit
        when Token::Type::ROLLBACK
          parse_rollback
        when Token::Type::EXPLAIN
          parse_explain
        when nil, Token::Type::EOF
          nil
        else
          raise ParserError, "Unexpected token: #{current_token}"
        end
      end

      def parse_select
        expect(Token::Type::SELECT)
        distinct = false
        if current_token&.type == Token::Type::DISTINCT
          advance
          distinct = true
        end

        columns = parse_select_columns
        expect(Token::Type::FROM)
        from = parse_table_reference

        where = nil
        if current_token&.type == Token::Type::WHERE
          advance
          where = parse_expression
        end

        order_by = nil
        if current_token&.type == Token::Type::ORDER
          advance
          expect(Token::Type::BY)
          order_by = parse_order_by
        end

        limit = nil
        if current_token&.type == Token::Type::LIMIT
          advance
          limit = parse_expression
        end

        offset = nil
        if current_token&.type == Token::Type::OFFSET
          advance
          offset = parse_expression
        end

        AST::Select.new(columns, from, where, order_by, limit, offset, distinct)
      end

      def parse_select_columns
        columns = []
        while true
          if current_token&.type == Token::Type::STAR
            columns << AST::Star.new
            advance
          else
            expr = parse_expression
            alias_name = nil
            if current_token&.type == Token::Type::AS
              advance
              alias_name = expect(Token::Type::IDENTIFIER)
              alias_name = alias_name.value
            elsif current_token&.type == Token::Type::IDENTIFIER
              # Implicit alias
              alias_name = current_token.value
              advance
            end
            columns << AST::SelectColumn.new(expr, alias_name)
          end

          break unless current_token&.type == Token::Type::COMMA
          advance
        end
        columns
      end

      def parse_table_reference
        table = expect(Token::Type::IDENTIFIER).value
        alias_name = nil
        if current_token&.type == Token::Type::AS
          advance
          alias_name = expect(Token::Type::IDENTIFIER).value
        elsif current_token&.type == Token::Type::IDENTIFIER
          alias_name = current_token.value
          advance
        end
        AST::TableRef.new(table, alias_name)
      end

      def parse_expression
        parse_or
      end

      def parse_or
        expr = parse_and
        while current_token&.type == Token::Type::OR
          advance
          right = parse_and
          expr = AST::BinaryOp.new(:or, expr, right)
        end
        expr
      end

      def parse_and
        expr = parse_comparison
        while current_token&.type == Token::Type::AND
          advance
          right = parse_comparison
          expr = AST::BinaryOp.new(:and, expr, right)
        end
        expr
      end

      def parse_comparison
        expr = parse_additive

        if current_token && Operators.comparison?(current_token.type)
          op = current_token.type
          advance
          right = parse_additive
          expr = AST::BinaryOp.new(op, expr, right)
        end

        if current_token&.type == Token::Type::IS
          advance
          is_not = current_token&.type == Token::Type::NOT
          advance if is_not
          expect(Token::Type::NULL)
          expr = AST::IsNull.new(expr, is_not)
        end

        if current_token&.type == Token::Type::BETWEEN
          advance
          low = parse_additive
          expect(Token::Type::AND)
          high = parse_additive
          expr = AST::Between.new(expr, low, high)
        end

        if current_token&.type == Token::Type::IN
          advance
          expect(Token::Type::LPAREN)
          values = []
          while true
            values << parse_expression
            break unless current_token&.type == Token::Type::COMMA
            advance
          end
          expect(Token::Type::RPAREN)
          expr = AST::In.new(expr, values)
        end

        expr
      end

      def parse_additive
        expr = parse_multiplicative
        while current_token && [Token::Type::PLUS, Token::Type::MINUS].include?(current_token.type)
          op = current_token.type
          advance
          right = parse_multiplicative
          expr = AST::BinaryOp.new(op, expr, right)
        end
        expr
      end

      def parse_multiplicative
        expr = parse_unary
        while current_token && [Token::Type::STAR, Token::Type::SLASH, Token::Type::PERCENT].include?(current_token.type)
          op = current_token.type
          advance
          right = parse_unary
          expr = AST::BinaryOp.new(op, expr, right)
        end
        expr
      end

      def parse_unary
        if current_token && Operators.unary?(current_token.type)
          op = current_token.type
          advance
          expr = parse_primary
          AST::UnaryOp.new(op, expr)
        else
          parse_primary
        end
      end

      def parse_primary
        case current_token&.type
        when Token::Type::LPAREN
          advance
          expr = parse_expression
          expect(Token::Type::RPAREN)
          expr
        when Token::Type::IDENTIFIER
          ident = current_token.value
          advance
          if current_token&.type == Token::Type::LPAREN
            # Function call
            advance
            args = []
            unless current_token&.type == Token::Type::RPAREN
              while true
                args << parse_expression
                break unless current_token&.type == Token::Type::COMMA
                advance
              end
            end
            expect(Token::Type::RPAREN)
            AST::FunctionCall.new(ident, args)
          else
            AST::Identifier.new(ident)
          end
        when Token::Type::STRING, Token::Type::NUMBER
          value = current_token.value
          type = current_token.type
          advance
          AST::Literal.new(value, type)
        when Token::Type::NULL
          advance
          AST::NullLiteral.new
        when Token::Type::TRUE
          advance
          AST::Literal.new(true, Token::Type::TRUE)
        when Token::Type::FALSE
          advance
          AST::Literal.new(false, Token::Type::FALSE)
        when Token::Type::PARAMETER
          value = current_token.value
          advance
          AST::Parameter.new(value)
        else
          raise ParserError, "Unexpected token in expression: #{current_token}"
        end
      end

      def parse_order_by
        order_items = []
        while true
          expr = parse_expression
          direction = :asc
          if current_token&.type == Token::Type::DESC
            direction = :desc
            advance
          end
          order_items << AST::OrderItem.new(expr, direction)
          break unless current_token&.type == Token::Type::COMMA
          advance
        end
        order_items
      end

      def parse_insert
        expect(Token::Type::INSERT)
        expect(Token::Type::INTO)
        table = expect(Token::Type::IDENTIFIER).value

        columns = []
        if current_token&.type == Token::Type::LPAREN
          advance
          while true
            columns << expect(Token::Type::IDENTIFIER).value
            break unless current_token&.type == Token::Type::COMMA
            advance
          end
          expect(Token::Type::RPAREN)
        end

        expect(Token::Type::VALUES)
        expect(Token::Type::LPAREN)
        values = []
        while true
          values << parse_expression
          break unless current_token&.type == Token::Type::COMMA
          advance
        end
        expect(Token::Type::RPAREN)

        AST::Insert.new(table, columns, values)
      end

      def parse_update
        expect(Token::Type::UPDATE)
        table = expect(Token::Type::IDENTIFIER).value
        expect(Token::Type::SET)

        assignments = []
        while true
          column = expect(Token::Type::IDENTIFIER).value
          expect(Token::Type::EQ)
          value = parse_expression
          assignments << AST::Assignment.new(column, value)
          break unless current_token&.type == Token::Type::COMMA
          advance
        end

        where = nil
        if current_token&.type == Token::Type::WHERE
          advance
          where = parse_expression
        end

        AST::Update.new(table, assignments, where)
      end

      def parse_delete
        expect(Token::Type::DELETE)
        expect(Token::Type::FROM)
        table = expect(Token::Type::IDENTIFIER).value

        where = nil
        if current_token&.type == Token::Type::WHERE
          advance
          where = parse_expression
        end

        AST::Delete.new(table, where)
      end

      def parse_create
        expect(Token::Type::CREATE)
        case current_token&.type
        when Token::Type::TABLE
          parse_create_table
        when Token::Type::INDEX
          parse_create_index
        when Token::Type::DATABASE
          parse_create_database
        else
          raise ParserError, "Unexpected CREATE type: #{current_token}"
        end
      end

      def parse_create_table
        advance # TABLE
        table_name = expect(Token::Type::IDENTIFIER).value
        expect(Token::Type::LPAREN)

        columns = []
        constraints = []

        while current_token&.type != Token::Type::RPAREN
          if current_token&.type == Token::Type::CONSTRAINT
            advance
            constraint_name = expect(Token::Type::IDENTIFIER).value
            constraint = parse_constraint(constraint_name)
            constraints << constraint
          elsif current_token&.type == Token::Type::PRIMARY ||
                current_token&.type == Token::Type::FOREIGN ||
                current_token&.type == Token::Type::UNIQUE ||
                current_token&.type == Token::Type::CHECK
            constraint = parse_constraint
            constraints << constraint if constraint
          else
            # Column definition
            column_name = expect(Token::Type::IDENTIFIER).value
            column_type = expect_data_type
            options = parse_column_options            columns << AST::ColumnDefinition.new(column_name, column_type, options)
          end

          break unless current_token&.type == Token::Type::COMMA
          advance
        end

        expect(Token::Type::RPAREN)

        AST::CreateTable.new(table_name, columns, constraints)
      end

      def parse_data_type
        case current_token&.type
        when Token::Type::INTEGER
          advance
          :integer
        when Token::Type::BIGINT
          advance
          :bigint
        when Token::Type::SMALLINT
          advance
          :smallint
        when Token::Type::FLOAT
          advance
          :float
        when Token::Type::DECIMAL
          advance
          if current_token&.type == Token::Type::LPAREN
            advance
            precision = expect(Token::Type::NUMBER).value
            scale = 0
            if current_token&.type == Token::Type::COMMA
              advance
              scale = expect(Token::Type::NUMBER).value
            end
            expect(Token::Type::RPAREN)
            { type: :decimal, precision: precision, scale: scale }
          else
            :decimal
          end
        when Token::Type::BOOLEAN
          advance
          :boolean
        when Token::Type::TEXT
          advance
          :text
        when Token::Type::VARCHAR
          advance
          if current_token&.type == Token::Type::LPAREN
            advance
            limit = expect(Token::Type::NUMBER).value
            expect(Token::Type::RPAREN)
            { type: :varchar, limit: limit }
          else
            { type: :varchar, limit: 255 }
          end
        when Token::Type::BLOB
          advance
          :blob
        when Token::Type::DATE
          advance
          :date
        when Token::Type::TIME
          advance
          :time
        when Token::Type::TIMESTAMP
          advance
          :timestamp
        when Token::Type::JSON
          advance
          :json
        when Token::Type::UUID
          advance
          :uuid
        else
          raise ParserError, "Expected data type, got: #{current_token}"
        end
      end

      def parse_column_options
        options = {}
        while true
          case current_token&.type
          when Token::Type::PRIMARY
            advance
            expect(Token::Type::KEY)
            options[:primary_key] = true
          when Token::Type::UNIQUE
            advance
            options[:unique] = true
          when Token::Type::NOT
            advance
            expect(Token::Type::NULL)
            options[:null] = false
          when Token::Type::NULL
            advance
            options[:null] = true
          when Token::Type::DEFAULT
            advance
            options[:default] = parse_expression
          when Token::Type::REFERENCES
            advance
            ref_table = expect(Token::Type::IDENTIFIER).value
            expect(Token::Type::LPAREN)
            ref_column = expect(Token::Type::IDENTIFIER).value
            expect(Token::Type::RPAREN)
            options[:references] = { table: ref_table, column: ref_column }
          else
            break
          end
        end
        options
      end

      def parse_constraint(name = nil)
        case current_token&.type
        when Token::Type::PRIMARY
          advance
          expect(Token::Type::KEY)
          expect(Token::Type::LPAREN)
          columns = []
          while true
            columns << expect(Token::Type::IDENTIFIER).value
            break unless current_token&.type == Token::Type::COMMA
            advance
          end
          expect(Token::Type::RPAREN)
          AST::PrimaryKeyConstraint.new(name, columns)
        when Token::Type::FOREIGN
          advance
          expect(Token::Type::KEY)
          expect(Token::Type::LPAREN)
          columns = []
          while true
            columns << expect(Token::Type::IDENTIFIER).value
            break unless current_token&.type == Token::Type::COMMA
            advance
          end
          expect(Token::Type::RPAREN)
          expect(Token::Type::REFERENCES)
          ref_table = expect(Token::Type::IDENTIFIER).value
          expect(Token::Type::LPAREN)
          ref_columns = []
          while true
            ref_columns << expect(Token::Type::IDENTIFIER).value
            break unless current_token&.type == Token::Type::COMMA
            advance
          end
          expect(Token::Type::RPAREN)
          AST::ForeignKeyConstraint.new(name, columns, ref_table, ref_columns)
        when Token::Type::UNIQUE
          advance
          expect(Token::Type::LPAREN)
          columns = []
          while true
            columns << expect(Token::Type::IDENTIFIER).value
            break unless current_token&.type == Token::Type::COMMA
            advance
          end
          expect(Token::Type::RPAREN)
          AST::UniqueConstraint.new(name, columns)
        when Token::Type::CHECK
          advance
          expect(Token::Type::LPAREN)
          condition = parse_expression
          expect(Token::Type::RPAREN)
          AST::CheckConstraint.new(name, condition)
        else
          nil
        end
      end

      def parse_create_index
        advance # INDEX
        index_name = expect(Token::Type::IDENTIFIER).value
        expect(Token::Type::ON)
        table_name = expect(Token::Type::IDENTIFIER).value
        expect(Token::Type::LPAREN)
        columns = []
        while true
          columns << expect(Token::Type::IDENTIFIER).value
          break unless current_token&.type == Token::Type::COMMA
          advance
        end
        expect(Token::Type::RPAREN)

        unique = false
        if current_token&.type == Token::Type::UNIQUE
          unique = true
          advance
        end

        AST::CreateIndex.new(index_name, table_name, columns, unique)
      end

      def parse_create_database
        advance # DATABASE
        db_name = expect(Token::Type::IDENTIFIER).value
        AST::CreateDatabase.new(db_name)
      end

      def parse_drop
        expect(Token::Type::DROP)
        case current_token&.type
        when Token::Type::TABLE
          advance
          table_name = expect(Token::Type::IDENTIFIER).value
          AST::DropTable.new(table_name)
        when Token::Type::INDEX
          advance
          index_name = expect(Token::Type::IDENTIFIER).value
          AST::DropIndex.new(index_name)
        when Token::Type::DATABASE
          advance
          db_name = expect(Token::Type::IDENTIFIER).value
          AST::DropDatabase.new(db_name)
        else
          raise ParserError, "Unexpected DROP type: #{current_token}"
        end
      end

      def parse_alter
        expect(Token::Type::ALTER)
        expect(Token::Type::TABLE)
        table_name = expect(Token::Type::IDENTIFIER).value

        case current_token&.type
        when Token::Type::ADD
          advance
          if current_token&.type == Token::Type::CONSTRAINT
            advance
            constraint_name = expect(Token::Type::IDENTIFIER).value
            constraint = parse_constraint(constraint_name)
            AST::AlterTableAddConstraint.new(table_name, constraint)
          else
            column_name = expect(Token::Type::IDENTIFIER).value
            column_type = parse_data_type
            options = parse_column_options
            AST::AlterTableAddColumn.new(table_name, column_name, column_type, options)
          end
        when Token::Type::DROP
          advance
          if current_token&.type == Token::Type::CONSTRAINT
            advance
            constraint_name = expect(Token::Type::IDENTIFIER).value
            AST::AlterTableDropConstraint.new(table_name, constraint_name)
          else
            column_name = expect(Token::Type::IDENTIFIER).value
            AST::AlterTableDropColumn.new(table_name, column_name)
          end
        else
          raise ParserError, "Unexpected ALTER TABLE operation: #{current_token}"
        end
      end

      def parse_begin
        expect(Token::Type::BEGIN_TRANSACTION)
        if current_token&.type == Token::Type::TRANSACTION
          advance
        end
        AST::BeginTransaction.new
      end

      def parse_commit
        expect(Token::Type::COMMIT)
        if current_token&.type == Token::Type::TRANSACTION
          advance
        end
        AST::Commit.new
      end

      def parse_rollback
        expect(Token::Type::ROLLBACK)
        if current_token&.type == Token::Type::TRANSACTION
          advance
        end
        if current_token&.type == Token::Type::TO
          advance
          savepoint = expect(Token::Type::IDENTIFIER).value
          return AST::RollbackToSavepoint.new(savepoint)
        end
        AST::Rollback.new
      end

      def parse_explain
        expect(Token::Type::EXPLAIN)
        if current_token&.type == Token::Type::ANALYZE
          advance
          analyze = true
        else
          analyze = false
        end
        statement = parse_statement
        AST::Explain.new(statement, analyze)
      end

      def expect(type)
        token = current_token
        if token.nil? || token.type != type
          raise ParserError, "Expected #{type}, got #{token}"
        end
        advance
        token
      end

      def expect_data_type
        type = parse_data_type
        unless type
          raise ParserError, "Expected data type, got #{current_token}"
        end
        type
      end

      def advance
        @position += 1
        @current_token = @tokens[@position]
      end
    end
  end
end