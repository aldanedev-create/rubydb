# frozen_string_literal: true

module RubyDB
  module SQL
    module AST
      # CREATE TABLE statement AST node
      class CreateTable < Node
        attr_reader :name, :columns, :constraints, :if_not_exists

        def initialize(name, columns, constraints = [], if_not_exists: false, location: nil)
          super(location: location)
          @name = name
          @columns = columns
          @constraints = constraints
          @if_not_exists = if_not_exists
        end

        def accept(visitor)
          visitor.visit_create_table(self)
        end

        def clone
          CreateTable.new(
            @name,
            @columns.map(&:clone),
            @constraints.map(&:clone),
            if_not_exists: @if_not_exists,
            location: @location
          )
        end

        def to_sql
          parts = []
          parts << "CREATE TABLE"
          parts << "IF NOT EXISTS" if @if_not_exists
          parts << @name
          parts << "("

          definitions = @columns.map(&:to_sql)
          definitions += @constraints.map(&:to_sql)
          parts << definitions.join(", ")

          parts << ")"
          parts.join(" ")
        end

        def inspect
          cols = @columns.map(&:inspect).join(", ")
          cons = @constraints.map(&:inspect).join(", ")
          str = "CreateTable(name: #{@name}, columns: [#{cols}]"
          str << ", constraints: [#{cons}]" if @constraints.any?
          str << ", if_not_exists: true" if @if_not_exists
          str << ")"
          str
        end

        # Helper methods
        def column_count
          @columns.size
        end

        def constraint_count
          @constraints.size
        end

        def find_column(name)
          @columns.find { |col| col.name == name }
        end

        def primary_key_columns
          pk = @constraints.find { |c| c.is_a?(PrimaryKeyConstraint) }
          pk ? pk.columns : []
        end

        def foreign_keys
          @constraints.select { |c| c.is_a?(ForeignKeyConstraint) }
        end

        def unique_constraints
          @constraints.select { |c| c.is_a?(UniqueConstraint) }
        end
      end

      # Column definition in CREATE TABLE
      class ColumnDefinition < Node
        attr_reader :name, :type, :options

        def initialize(name, type, options = {}, location: nil)
          super(location: location)
          @name = name
          @type = type
          @options = options
        end

        def accept(visitor)
          visitor.visit_column_definition(self)
        end

        def clone
          ColumnDefinition.new(
            @name,
            @type.is_a?(Hash) ? @type.dup : @type,
            @options.dup,
            location: @location
          )
        end

        def to_sql
          parts = [@name]
          parts << type_sql
          parts << "PRIMARY KEY" if @options[:primary_key]
          parts << "UNIQUE" if @options[:unique]
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
          "ColumnDefinition(name: #{@name}, type: #{type_sql}, options: #{@options.inspect})"
        end

        def type_sql
          case @type
          when Symbol
            @type.to_s.upcase
          when Hash
            if @type[:type] == :decimal
              "DECIMAL(#{@type[:precision]}, #{@type[:scale]})"
            elsif @type[:type] == :varchar
              "VARCHAR(#{@type[:limit]})"
            else
              @type[:type].to_s.upcase
            end
          else
            @type.to_s
          end
        end

        def type_class
          case @type
          when Symbol
            @type
          when Hash
            @type[:type]
          else
            @type
          end
        end

        def type_params
          case @type
          when Hash
            @type.reject { |k| k == :type }
          else
            {}
          end
        end

        def primary_key?
          @options[:primary_key] == true
        end

        def unique?
          @options[:unique] == true
        end

        def nullable?
          @options[:null] != false
        end

        def has_default?
          !@options[:default].nil?
        end

        def references?
          !@options[:references].nil?
        end
      end
    end
  end
end