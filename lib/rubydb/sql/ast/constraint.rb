# frozen_string_literal: true

module RubyDB
  module SQL
    module AST
      class ConstraintDefinition < Node
        attr_reader :name

        def initialize(name, location: nil)
          super(location: location)
          @name = name
        end

        def accept(visitor)
          visitor.public_send("visit_#{constraint_visit_name}", self)
        end

        def clone
          self.class.new(@name, location: @location)
        end

        private

        def constraint_visit_name
          self.class.name.split("::").last.gsub(/([a-z\d])([A-Z])/, '\\1_\\2').downcase
        end
      end

      class PrimaryKeyConstraint < ConstraintDefinition
        attr_reader :columns
        def initialize(name, columns, location: nil)
          super(name, location: location)
          @columns = Array(columns)
        end
        def clone = self.class.new(@name, @columns.dup, location: @location)
        def to_sql = "CONSTRAINT #{@name} PRIMARY KEY (#{@columns.join(', ')})"
      end

      class ForeignKeyConstraint < ConstraintDefinition
        attr_reader :columns, :reference_table, :reference_columns, :on_delete, :on_update
        def initialize(name, columns, reference_table, reference_columns, on_delete: nil, on_update: nil, location: nil)
          super(name, location: location)
          @columns = Array(columns)
          @reference_table = reference_table
          @reference_columns = Array(reference_columns)
          @on_delete = on_delete
          @on_update = on_update
        end
        def clone = self.class.new(@name, @columns.dup, @reference_table, @reference_columns.dup, on_delete: @on_delete, on_update: @on_update, location: @location)
        def to_sql
          sql = "CONSTRAINT #{@name} FOREIGN KEY (#{@columns.join(', ')}) REFERENCES #{@reference_table} (#{@reference_columns.join(', ')})"
          sql << " ON DELETE #{@on_delete.to_s.upcase.tr('_', ' ')}" if @on_delete
          sql << " ON UPDATE #{@on_update.to_s.upcase.tr('_', ' ')}" if @on_update
          sql
        end
      end

      class UniqueConstraint < ConstraintDefinition
        attr_reader :columns
        def initialize(name, columns, location: nil)
          super(name, location: location)
          @columns = Array(columns)
        end
        def clone = self.class.new(@name, @columns.dup, location: @location)
        def to_sql = "CONSTRAINT #{@name} UNIQUE (#{@columns.join(', ')})"
      end

      class CheckConstraint < ConstraintDefinition
        attr_reader :condition
        def initialize(name, condition, location: nil)
          super(name, location: location)
          @condition = condition
        end
        def accept(visitor)
          super
          @condition.accept(visitor) if @condition.respond_to?(:accept)
        end
        def clone = self.class.new(@name, @condition.clone, location: @location)
        def to_sql = "CONSTRAINT #{@name} CHECK (#{@condition.to_sql})"
      end
    end
  end
end
