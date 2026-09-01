# frozen_string_literal: true

module RubyDB
  module SQL
    module AST
      # UPDATE statement AST node
      class Update < Node
        attr_reader :table, :assignments, :where

        def initialize(table, assignments, where = nil, location: nil)
          super(location: location)
          @table = table
          @assignments = assignments
          @where = where
        end

        def accept(visitor)
          visitor.visit_update(self)
        end

        def clone
          Update.new(
            @table,
            @assignments.map(&:clone),
            @where&.clone,
            location: @location
          )
        end

        def to_sql
          parts = []
          parts << "UPDATE #{@table}"
          parts << "SET #{@assignments.map(&:to_sql).join(", ")}"
          parts << "WHERE #{@where.to_sql}" if @where
          parts.join(" ")
        end

        def inspect
          ass = @assignments.map(&:inspect).join(", ")
          str = "Update(table: #{@table}, assignments: [#{ass}]"
          str << ", where: #{@where.inspect}" if @where
          str << ")"
          str
        end

        # Helper methods
        def assignment_count
          @assignments.size
        end

        def has_where?
          !@where.nil?
        end

        def updated_columns
          @assignments.map(&:column)
        end
      end

      # Assignment in UPDATE statement
      class Assignment < Node
        attr_reader :column, :value

        def initialize(column, value, location: nil)
          super(location: location)
          @column = column
          @value = value
        end

        def accept(visitor)
          visitor.visit_assignment(self)
        end

        def clone
          Assignment.new(@column, @value.clone, location: @location)
        end

        def to_sql
          "#{@column} = #{@value.to_sql}"
        end

        def inspect
          "Assignment(#{@column} = #{@value.inspect})"
        end
      end
    end
  end
end