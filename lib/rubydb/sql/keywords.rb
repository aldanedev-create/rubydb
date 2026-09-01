# frozen_string_literal: true

module RubyDB
  module SQL
    # SQL keyword definitions
    module Keywords
      # Map of keyword strings to token types
      KEYWORD_MAP = {
        "SELECT" => Token::Type::SELECT,
        "INSERT" => Token::Type::INSERT,
        "UPDATE" => Token::Type::UPDATE,
        "DELETE" => Token::Type::DELETE,
        "CREATE" => Token::Type::CREATE,
        "ALTER" => Token::Type::ALTER,
        "DROP" => Token::Type::DROP,
        "TABLE" => Token::Type::TABLE,
        "INDEX" => Token::Type::INDEX,
        "DATABASE" => Token::Type::DATABASE,
        "SCHEMA" => Token::Type::SCHEMA,
        "VIEW" => Token::Type::VIEW,
        "TRIGGER" => Token::Type::TRIGGER,
        "FROM" => Token::Type::FROM,
        "WHERE" => Token::Type::WHERE,
        "SET" => Token::Type::SET,
        "VALUES" => Token::Type::VALUES,
        "INTO" => Token::Type::INTO,
        "JOIN" => Token::Type::JOIN,
        "INNER" => Token::Type::INNER,
        "LEFT" => Token::Type::LEFT,
        "RIGHT" => Token::Type::RIGHT,
        "OUTER" => Token::Type::OUTER,
        "FULL" => Token::Type::FULL,
        "ON" => Token::Type::ON,
        "AS" => Token::Type::AS,
        "DISTINCT" => Token::Type::DISTINCT,
        "ORDER" => Token::Type::ORDER,
        "BY" => Token::Type::BY,
        "GROUP" => Token::Type::GROUP,
        "HAVING" => Token::Type::HAVING,
        "LIMIT" => Token::Type::LIMIT,
        "OFFSET" => Token::Type::OFFSET,
        "UNION" => Token::Type::UNION,
        "INTERSECT" => Token::Type::INTERSECT,
        "EXCEPT" => Token::Type::EXCEPT,
        "ALL" => Token::Type::ALL,
        "ANY" => Token::Type::ANY,
        "SOME" => Token::Type::SOME,
        "EXISTS" => Token::Type::EXISTS,
        "BETWEEN" => Token::Type::BETWEEN,
        "LIKE" => Token::Type::LIKE,
        "ILIKE" => Token::Type::ILIKE,
        "IN" => Token::Type::IN,
        "IS" => Token::Type::IS,
        "NULL" => Token::Type::NULL,
        "NOT" => Token::Type::NOT,
        "AND" => Token::Type::AND,
        "OR" => Token::Type::OR,
        "TRUE" => Token::Type::TRUE,
        "FALSE" => Token::Type::FALSE,
        "PRIMARY" => Token::Type::PRIMARY,
        "FOREIGN" => Token::Type::FOREIGN,
        "KEY" => Token::Type::KEY,
        "UNIQUE" => Token::Type::UNIQUE,
        "CHECK" => Token::Type::CHECK,
        "DEFAULT" => Token::Type::DEFAULT,
        "REFERENCES" => Token::Type::REFERENCES,
        "CONSTRAINT" => Token::Type::CONSTRAINT,
        "CASCADE" => Token::Type::CASCADE,
        "RESTRICT" => Token::Type::RESTRICT,
        "ADD" => Token::Type::ADD,
        "TO" => Token::Type::TO,
        "BEGIN" => Token::Type::BEGIN_TRANSACTION,
        "COMMIT" => Token::Type::COMMIT,
        "ROLLBACK" => Token::Type::ROLLBACK,
        "SAVEPOINT" => Token::Type::SAVEPOINT,
        "TRANSACTION" => Token::Type::TRANSACTION,
        "EXPLAIN" => Token::Type::EXPLAIN,
        "ANALYZE" => Token::Type::ANALYZE,
        "VACUUM" => Token::Type::VACUUM,
        "INTEGER" => Token::Type::INTEGER,
        "BIGINT" => Token::Type::BIGINT,
        "SMALLINT" => Token::Type::SMALLINT,
        "FLOAT" => Token::Type::FLOAT,
        "DECIMAL" => Token::Type::DECIMAL,
        "NUMERIC" => Token::Type::NUMERIC,
        "BOOLEAN" => Token::Type::BOOLEAN,
        "TEXT" => Token::Type::TEXT,
        "VARCHAR" => Token::Type::VARCHAR,
        "CHAR" => Token::Type::CHAR,
        "BLOB" => Token::Type::BLOB,
        "DATE" => Token::Type::DATE,
        "TIME" => Token::Type::TIME,
        "TIMESTAMP" => Token::Type::TIMESTAMP,
        "JSON" => Token::Type::JSON,
        "UUID" => Token::Type::UUID
      }.freeze

      # SQL keywords that are reserved
      RESERVED_KEYWORDS = %w[
        SELECT INSERT UPDATE DELETE CREATE ALTER DROP
        TABLE INDEX DATABASE SCHEMA VIEW TRIGGER
        FROM WHERE SET VALUES INTO JOIN ON AS
        DISTINCT ORDER BY GROUP HAVING LIMIT OFFSET
        UNION INTERSECT EXCEPT ALL ANY SOME EXISTS
        BETWEEN LIKE ILIKE IN IS NULL NOT AND OR
        TRUE FALSE PRIMARY FOREIGN KEY UNIQUE CHECK
        DEFAULT REFERENCES CONSTRAINT CASCADE RESTRICT
        BEGIN COMMIT ROLLBACK SAVEPOINT TRANSACTION
      ].freeze

      # Data type keywords
      TYPE_KEYWORDS = %w[
        INTEGER BIGINT SMALLINT FLOAT DECIMAL NUMERIC
        BOOLEAN TEXT VARCHAR CHAR BLOB DATE TIME TIMESTAMP
        JSON UUID
      ].freeze

      def self.keyword?(word)
        KEYWORD_MAP.key?(word.upcase)
      end

      def self.token_type(word)
        KEYWORD_MAP[word.upcase]
      end

      def self.reserved?(word)
        RESERVED_KEYWORDS.include?(word.upcase)
      end

      def self.type_keyword?(word)
        TYPE_KEYWORDS.include?(word.upcase)
      end
    end
  end
end