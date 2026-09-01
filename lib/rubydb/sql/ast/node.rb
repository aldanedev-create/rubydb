# frozen_string_literal: true

module RubyDB
  module SQL
    module AST
      # Base class for all AST nodes
      class Node
        attr_reader :location

        def initialize(location: nil)
          @location = location
        end

        # Accept a visitor for traversal
        def accept(visitor)
          raise NotImplementedError, "#{self.class} must implement #accept"
        end

        # Deep clone of the node
        def clone
          raise NotImplementedError, "#{self.class} must implement #clone"
        end

        # Convert to SQL string
        def to_sql
          raise NotImplementedError, "#{self.class} must implement #to_sql"
        end

        # Compare two nodes for equality
        def ==(other)
          self.class == other.class && instance_variables.all? do |ivar|
            instance_variable_get(ivar) == other.instance_variable_get(ivar)
          end
        end

        def inspect
          "#<#{self.class}>"
        end
      end
    end
  end
end