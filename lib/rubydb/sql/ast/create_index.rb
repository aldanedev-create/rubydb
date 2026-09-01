# frozen_string_literal: true

module RubyDB
  module SQL
    module AST
      # CREATE INDEX statement AST node
      class CreateIndex < Node
        attr_reader :name, :table_name, :columns, :unique, :if_not_exists

        def initialize(name, table_name, columns, unique: false, if_not_exists: false, location: nil)
          super(location: location)
          @name = name
          @table_name = table_name
          @columns = columns
          @unique = unique
          @if_not_exists = if_not_exists
        end

        def accept(visitor)
          visitor.visit_create_index(self)
        end

        def clone
          CreateIndex.new(
            @name,
            @table_name,
            @columns.dup,
            unique: @unique,
            if_not_exists: @if_not_exists,
            location: @location
          )
        end

        def to_sql
          parts = []
          parts << "CREATE"
          parts << "UNIQUE" if @unique
          parts << "INDEX"
          parts << "IF NOT EXISTS" if @if_not_exists
          parts << @name
          parts << "ON"
          parts << @table_name
          parts << "(#{@columns.join(", ")})"
          parts.join(" ")
        end

        def inspect
          str = "CreateIndex(name: #{@name}, table: #{@table_name}, columns: [#{@columns.join(", ")}]"
          str << ", unique: true" if @unique
          str << ", if_not_exists: true" if @if_not_exists
          str << ")"
          str
        end

        def column_count
          @columns.size
        end
      end
    end
  end
end