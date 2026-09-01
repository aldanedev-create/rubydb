# frozen_string_literal: true

module RubyDB
  module SQL
    module AST
      # EXPLAIN statement AST node
      class Explain < Node
        attr_reader :statement, :analyze, :verbose, :costs, :buffers, :timing, :format

        def initialize(statement, analyze: false, verbose: false, costs: true, buffers: false, timing: true, format: nil, location: nil)
          super(location: location)
          @statement = statement
          @analyze = analyze
          @verbose = verbose
          @costs = costs
          @buffers = buffers
          @timing = timing
          @format = format || :text
        end

        def accept(visitor)
          visitor.visit_explain(self)
        end

        def clone
          Explain.new(
            @statement.clone,
            analyze: @analyze,
            verbose: @verbose,
            costs: @costs,
            buffers: @buffers,
            timing: @timing,
            format: @format,
            location: @location
          )
        end

        def to_sql
          parts = ["EXPLAIN"]
          parts << "ANALYZE" if @analyze
          parts << "VERBOSE" if @verbose
          parts << "COSTS" if @costs
          parts << "BUFFERS" if @buffers
          parts << "TIMING" if @timing
          parts << "(FORMAT #{@format.to_s.upcase})" if @format
          parts << @statement.to_sql
          parts.join(" ")
        end

        def inspect
          str = "Explain(statement: #{@statement.inspect}"
          str << ", analyze: true" if @analyze
          str << ", verbose: true" if @verbose
          str << ", costs: false" unless @costs
          str << ", buffers: true" if @buffers
          str << ", timing: false" unless @timing
          str << ", format: #{@format}" if @format
          str << ")"
          str
        end
      end
    end
  end
end