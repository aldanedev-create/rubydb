# frozen_string_literal: true

module RubyDB
  module SQL
    module AST
      # DELETE statement AST node
      class Delete < Node
        attr_reader :table, :where

        def initialize(table, where = nil, location: nil)
          super(location: location)
          @table = table
          @where = where
        end

        def accept(visitor)
          visitor.visit_delete(self)
        end

        def clone
          Delete.new(
            @table,
            @where&.clone,
            location: @location
          )
        end

        def to_sql
          parts = []
          parts << "DELETE FROM #{@table}"
          parts << "WHERE #{@where.to_sql}" if @where
          parts.join(" ")
        end

        def inspect
          str = "Delete(table: #{@table}"
          str << ", where: #{@where.inspect}" if @where
          str << ")"
          str
        end

        # Helper methods
        def has_where?
          !@where.nil?
        end

        # Check if this DELETE will affect all rows
        def delete_all?
          @where.nil?
        end
      end
    end
  end
end