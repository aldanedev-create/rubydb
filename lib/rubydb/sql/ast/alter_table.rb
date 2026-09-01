# frozen_string_literal: true

module RubyDB
  module SQL
    module AST
      # ALTER TABLE statement AST node (base)
      class AlterTable < Node
        attr_reader :table_name

        def initialize(table_name, location: nil)
          super(location: location)
          @table_name = table_name
        end

        def to_sql
          "ALTER TABLE #{@table_name}"
        end

        def inspect
          "AlterTable(table: #{@table_name})"
        end
      end

      # ALTER TABLE ADD COLUMN
      class AlterTableAddColumn < AlterTable
        attr_reader :column_name, :column_type, :options

        def initialize(table_name, column_name, column_type, options = {}, location: nil)
          super(table_name, location: location)
          @column_name = column_name
          @column_type = column_type
          @options = options
        end

        def accept(visitor)
          visitor.visit_alter_table_add_column(self)
        end

        def clone
          AlterTableAddColumn.new(
            @table_name,
            @column_name,
            @column_type.is_a?(Hash) ? @column_type.dup : @column_type,
            @options.dup,
            location: @location
          )
        end

        def to_sql
          parts = [super]
          parts << "ADD"
          parts << @column_name
          parts << type_sql
          parts << "NOT NULL" if @options[:null] == false
          parts << "NULL" if @options[:null] == true
          parts << "DEFAULT #{@options[:default].to_sql}" if @options[:default]
          if @options[:references]
            ref = @options[:references]
            parts << "REFERENCES #{ref[:table]}(#{ref[:column]})"
          end
          parts.join(" ")
        end

        def inspect
          "AlterTableAddColumn(table: #{@table_name}, column: #{@column_name}, type: #{type_sql}, options: #{@options.inspect})"
        end

        def type_sql
          case @column_type
          when Symbol
            @column_type.to_s.upcase
          when Hash
            if @column_type[:type] == :decimal
              "DECIMAL(#{@column_type[:precision]}, #{@column_type[:scale]})"
            elsif @column_type[:type] == :varchar
              "VARCHAR(#{@column_type[:limit]})"
            else
              @column_type[:type].to_s.upcase
            end
          else
            @column_type.to_s
          end
        end
      end

      # ALTER TABLE DROP COLUMN
      class AlterTableDropColumn < AlterTable
        attr_reader :column_name

        def initialize(table_name, column_name, location: nil)
          super(table_name, location: location)
          @column_name = column_name
        end

        def accept(visitor)
          visitor.visit_alter_table_drop_column(self)
        end

        def clone
          AlterTableDropColumn.new(@table_name, @column_name, location: @location)
        end

        def to_sql
          "#{super} DROP COLUMN #{@column_name}"
        end

        def inspect
          "AlterTableDropColumn(table: #{@table_name}, column: #{@column_name})"
        end
      end

      # ALTER TABLE ADD CONSTRAINT
      class AlterTableAddConstraint < AlterTable
        attr_reader :constraint

        def initialize(table_name, constraint, location: nil)
          super(table_name, location: location)
          @constraint = constraint
        end

        def accept(visitor)
          visitor.visit_alter_table_add_constraint(self)
        end

        def clone
          AlterTableAddConstraint.new(
            @table_name,
            @constraint.clone,
            location: @location
          )
        end

        def to_sql
          "#{super} ADD #{@constraint.to_sql}"
        end

        def inspect
          "AlterTableAddConstraint(table: #{@table_name}, constraint: #{@constraint.inspect})"
        end
      end

      # ALTER TABLE DROP CONSTRAINT
      class AlterTableDropConstraint < AlterTable
        attr_reader :constraint_name

        def initialize(table_name, constraint_name, location: nil)
          super(table_name, location: location)
          @constraint_name = constraint_name
        end

        def accept(visitor)
          visitor.visit_alter_table_drop_constraint(self)
        end

        def clone
          AlterTableDropConstraint.new(@table_name, @constraint_name, location: @location)
        end

        def to_sql
          "#{super} DROP CONSTRAINT #{@constraint_name}"
        end

        def inspect
          "AlterTableDropConstraint(table: #{@table_name}, constraint: #{@constraint_name})"
        end
      end
    end
  end
end