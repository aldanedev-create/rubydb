# frozen_string_literal: true

module RubyDB
  module SQL
    module AST
      class SetOperation < Node
        attr_reader :left, :right, :operator, :all

        def initialize(left, right, operator, all: false, location: nil)
          super(location: location)
          @left, @right, @operator, @all = left, right, operator, all
        end

        def accept(visitor) = visitor.visit_set_operation(self)

        def clone = SetOperation.new(@left.clone, @right.clone, @operator, all: @all, location: @location)

        def to_sql = "#{@left.to_sql} #{@operator.to_s.upcase}#{@all ? " ALL" : ""} #{@right.to_sql}"
      end
    end
  end
end
