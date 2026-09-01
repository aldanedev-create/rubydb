# frozen_string_literal: true

module RubyDB
  module Functions
    # AggregateFunction - Base class for aggregate functions
    class AggregateFunction < Function
      attr_reader :state_type

      def initialize(name, options = {})
        super(name, TYPE_AGGREGATE, options)
        @state_type = options[:state_type] || :text
        @initial_state = options[:initial_state] || nil
        @is_distinct = false
        @is_ordered = false
      end

      def execute(args)
        validate_args(args)
        # For aggregate functions, args is an array of values
        args = args.flatten if args.is_a?(Array)
        execute_aggregate(args)
      end

      def execute_aggregate(values)
        raise NotImplementedError, "#{self.class} must implement #execute_aggregate"
      end

      def aggregate_batch(values)
        # Default implementation: iterate through values
        result = nil
        values.each do |val|
          result = combine(result, val)
        end
        result
      end

      def combine(state, value)
        raise NotImplementedError, "#{self.class} must implement #combine"
      end

      def finalize(state)
        state
      end

      def distinct?
        @is_distinct
      end

      def ordered?
        @is_ordered
      end

      def set_distinct(distinct)
        @is_distinct = distinct
      end

      def set_ordered(ordered)
        @is_ordered = ordered
      end

      def to_hash
        super.merge({
          state_type: @state_type,
          distinct: @is_distinct,
          ordered: @is_ordered
        })
      end
    end
  end
end