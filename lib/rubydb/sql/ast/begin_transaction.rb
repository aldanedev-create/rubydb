# frozen_string_literal: true

module RubyDB
  module SQL
    module AST
      # BEGIN TRANSACTION statement AST node
      class BeginTransaction < Node
        attr_reader :isolation_level, :read_only

        def initialize(isolation_level: nil, read_only: false, location: nil)
          super(location: location)
          @isolation_level = isolation_level
          @read_only = read_only
        end

        def accept(visitor)
          visitor.visit_begin_transaction(self)
        end

        def clone
          BeginTransaction.new(
            isolation_level: @isolation_level,
            read_only: @read_only,
            location: @location
          )
        end

        def to_sql
          parts = ["BEGIN"]
          if @isolation_level
            parts << "ISOLATION LEVEL"
            parts << @isolation_level.to_s.upcase
          end
          parts << "READ ONLY" if @read_only
          parts.join(" ")
        end

        def inspect
          str = "BeginTransaction"
          str << " (isolation_level: #{@isolation_level})" if @isolation_level
          str << " (read_only: true)" if @read_only
          str
        end
      end
    end
  end
end