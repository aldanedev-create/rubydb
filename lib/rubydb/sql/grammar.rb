# frozen_string_literal: true

module RubyDB
  module SQL
    # SQL Grammar definitions - used for validation and reference
    module Grammar
      # SQL statement types
      STATEMENT_TYPES = {
        select: "SELECT ... FROM ... [WHERE ...] [ORDER BY ...] [LIMIT ...] [OFFSET ...]",
        insert: "INSERT INTO table [(columns)] VALUES (values)",
        update: "UPDATE table SET column = value [WHERE ...]",
        delete: "DELETE FROM table [WHERE ...]",
        create_table: "CREATE TABLE name (column_definitions [, constraints])",
        create_index: "CREATE [UNIQUE] INDEX name ON table (columns)",
        create_database: "CREATE DATABASE name",
        drop_table: "DROP TABLE name",
        drop_index: "DROP INDEX name",
        drop_database: "DROP DATABASE name",
        alter_table: "ALTER TABLE name ADD/DROP column/constraint",
        begin: "BEGIN [TRANSACTION]",
        commit: "COMMIT [TRANSACTION]",
        rollback: "ROLLBACK [TRANSACTION] [TO SAVEPOINT name]",
        explain: "EXPLAIN [ANALYZE] statement"
      }.freeze

      # Column data types
      DATA_TYPES = {
        integer: "INTEGER",
        bigint: "BIGINT",
        smallint: "SMALLINT",
        float: "FLOAT",
        decimal: "DECIMAL(precision, scale)",
        numeric: "NUMERIC(precision, scale)",
        boolean: "BOOLEAN",
        text: "TEXT",
        varchar: "VARCHAR(length)",
        char: "CHAR(length)",
        blob: "BLOB",
        date: "DATE",
        time: "TIME",
        timestamp: "TIMESTAMP",
        json: "JSON",
        uuid: "UUID"
      }.freeze

      # Operators
      OPERATORS = {
        comparison: ["=", "!=", "<>", "<", "<=", ">", ">="],
        logical: ["AND", "OR", "NOT"],
        arithmetic: ["+", "-", "*", "/", "%"],
        bitwise: ["&", "|", "^", "~"],
        other: ["LIKE", "ILIKE", "BETWEEN", "IN", "IS", "IS NOT"]
      }.freeze

      # Constraint types
      CONSTRAINT_TYPES = {
        primary_key: "PRIMARY KEY (columns)",
        foreign_key: "FOREIGN KEY (columns) REFERENCES table (columns)",
        unique: "UNIQUE (columns)",
        check: "CHECK (condition)",
        not_null: "NOT NULL"
      }.freeze

      def self.validate_statement_type(type)
        STATEMENT_TYPES.key?(type) ? true : false
      end

      def self.validate_data_type(type)
        DATA_TYPES.key?(type) ? true : false
      end

      def self.validate_operator(op)
        OPERATORS.values.flatten.include?(op.to_s.upcase)
      end

      def self.validate_constraint_type(type)
        CONSTRAINT_TYPES.key?(type) ? true : false
      end
    end
  end
end