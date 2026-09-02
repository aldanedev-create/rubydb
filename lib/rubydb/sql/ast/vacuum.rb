# frozen_string_literal: true

module RubyDB
  module SQL
    module AST
      class Vacuum < Node
        def accept(visitor)
          visitor.visit_vacuum(self)
        end

        def clone
          self.class.new(location: @location)
        end

        def to_sql = "VACUUM"
      end
    end
  end
end
