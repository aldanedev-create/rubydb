# frozen_string_literal: true

module RubyDB
  module SQL
    # Token types for SQL lexer
    class Token
      # Token types
      module Type
        # Keywords
        SELECT = :SELECT
        INSERT = :INSERT
        UPDATE = :UPDATE
        DELETE = :DELETE
        CREATE = :CREATE
        ALTER = :ALTER
        DROP = :DROP
        TABLE = :TABLE
        INDEX = :INDEX
        DATABASE = :DATABASE
        SCHEMA = :SCHEMA
        VIEW = :VIEW
        TRIGGER = :TRIGGER
        FROM = :FROM
        WHERE = :WHERE
        SET = :SET
        VALUES = :VALUES
        INTO = :INTO
        JOIN = :JOIN
        INNER = :INNER
        LEFT = :LEFT
        RIGHT = :RIGHT
        OUTER = :OUTER
        FULL = :FULL
        ON = :ON
        AS = :AS
        DISTINCT = :DISTINCT
        ORDER = :ORDER
        BY = :BY
        GROUP = :GROUP
        HAVING = :HAVING
        LIMIT = :LIMIT
        OFFSET = :OFFSET
        UNION = :UNION
        INTERSECT = :INTERSECT
        EXCEPT = :EXCEPT
        ALL = :ALL
        ANY = :ANY
        SOME = :SOME
        EXISTS = :EXISTS
        BETWEEN = :BETWEEN
        LIKE = :LIKE
        ILIKE = :ILIKE
        IN = :IN
        IS = :IS
        NULL = :NULL
        NOT = :NOT
        AND = :AND
        OR = :OR
        TRUE = :TRUE
        FALSE = :FALSE
        PRIMARY = :PRIMARY
        FOREIGN = :FOREIGN
        KEY = :KEY
        UNIQUE = :UNIQUE
        CHECK = :CHECK
        DEFAULT = :DEFAULT
        REFERENCES = :REFERENCES
        CONSTRAINT = :CONSTRAINT
        CASCADE = :CASCADE
        RESTRICT = :RESTRICT
        ADD = :ADD
        TO = :TO
        BEGIN_TRANSACTION = :BEGIN
        COMMIT = :COMMIT
        ROLLBACK = :ROLLBACK
        SAVEPOINT = :SAVEPOINT
        TRANSACTION = :TRANSACTION
        EXPLAIN = :EXPLAIN
        ANALYZE = :ANALYZE
        VACUUM = :VACUUM

        # Data types
        INTEGER = :INTEGER
        BIGINT = :BIGINT
        SMALLINT = :SMALLINT
        FLOAT = :FLOAT
        DECIMAL = :DECIMAL
        NUMERIC = :NUMERIC
        BOOLEAN = :BOOLEAN
        TEXT = :TEXT
        VARCHAR = :VARCHAR
        CHAR = :CHAR
        BLOB = :BLOB
        DATE = :DATE
        TIME = :TIME
        TIMESTAMP = :TIMESTAMP
        JSON = :JSON
        UUID = :UUID

        # Operators
        EQ = :EQ              # =
        NE = :NE              # != or <>
        LT = :LT              # <
        LTE = :LTE            # <=
        GT = :GT              # >
        GTE = :GTE            # >=
        PLUS = :PLUS          # +
        MINUS = :MINUS        # -
        STAR = :STAR          # *
        SLASH = :SLASH        # /
        PERCENT = :PERCENT    # %
        AMPERSAND = :AMPERSAND # &
        PIPE = :PIPE          # |
        CARET = :CARET        # ^
        TILDE = :TILDE        # ~

        # Punctuation
        LPAREN = :LPAREN      # (
        RPAREN = :RPAREN      # )
        COMMA = :COMMA        # ,
        SEMICOLON = :SEMICOLON # ;
        DOT = :DOT            # .
        LBRACKET = :LBRACKET  # [
        RBRACKET = :RBRACKET  # ]
        LBRACE = :LBRACE      # {
        RBRACE = :RBRACE      # }

        # Literals
        IDENTIFIER = :IDENTIFIER
        STRING = :STRING
        NUMBER = :NUMBER
        BLOB_LITERAL = :BLOB_LITERAL

        # Special
        EOF = :EOF
        COMMENT = :COMMENT
        PARAMETER = :PARAMETER  # ? or $1, $2, etc.
      end

      attr_reader :type, :value, :line, :column

      def initialize(type, value = nil, line: 1, column: 1)
        @type = type
        @value = value
        @line = line
        @column = column
      end

      def keyword?
        @type.to_s.start_with?("KEYWORD_") || false
      end

      def operator?
        [
          Type::EQ, Type::NE, Type::LT, Type::LTE,
          Type::GT, Type::GTE, Type::PLUS, Type::MINUS,
          Type::STAR, Type::SLASH, Type::PERCENT,
          Type::AMPERSAND, Type::PIPE, Type::CARET, Type::TILDE
        ].include?(@type)
      end

      def literal?
        [Type::STRING, Type::NUMBER, Type::BLOB_LITERAL].include?(@type)
      end

      def identifier?
        @type == Type::IDENTIFIER
      end

      def to_s
        if @value
          "#{@type}(#{@value})"
        else
          @type.to_s
        end
      end

      def inspect
        to_s
      end

      # Equality check for testing
      def ==(other)
        return false unless other.is_a?(Token)
        @type == other.type && @value == other.value
      end
    end
  end
end