# frozen_string_literal: true

module RubyDB
  module SQL
    module AST
      class CreateTrigger < Node
        attr_reader :name, :timing, :event, :table_name, :function_name
        def initialize(name, timing, event, table_name, function_name, location: nil)
          super(location: location)
          @name, @timing, @event, @table_name, @function_name = name, timing, event, table_name, function_name
        end
        def accept(visitor) = visitor.visit_create_trigger(self)
        def clone = self.class.new(@name, @timing, @event, @table_name, @function_name, location: @location)
        def to_sql = "CREATE TRIGGER #{@name} #{@timing.to_s.upcase} #{@event.to_s.upcase} ON #{@table_name} EXECUTE FUNCTION #{@function_name}()"
      end

      class DropTrigger < Node
        attr_reader :name, :if_exists
        def initialize(name, if_exists: false, location: nil)
          super(location: location)
          @name, @if_exists = name, if_exists
        end
        def accept(visitor) = visitor.visit_drop_trigger(self)
        def clone = self.class.new(@name, if_exists: @if_exists, location: @location)
        def to_sql = "DROP TRIGGER #{@name}"
      end
    end
  end
end
