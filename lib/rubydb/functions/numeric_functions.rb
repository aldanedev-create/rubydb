# frozen_string_literal: true

module RubyDB
  module Functions
    # NumericFunctions - All numeric-related functions
    class NumericFunctions
      # ABS - Absolute value
      class Abs < ScalarFunction
        def initialize
          super(:abs,
            description: "Absolute value",
            category: :numeric,
            min_args: 1,
            max_args: 1,
            return_type: :numeric,
            deterministic: true,
            immutable: true
          )
        end

        def execute_scalar(args)
          return nil if args[0].nil?
          val = args[0].to_f
          val.abs
        end
      end

      # CEIL - Ceiling value
      class Ceil < ScalarFunction
        def initialize
          super(:ceil,
            description: "Ceiling value",
            category: :numeric,
            min_args: 1,
            max_args: 1,
            return_type: :numeric,
            deterministic: true,
            immutable: true
          )
        end

        def execute_scalar(args)
          return nil if args[0].nil?
          val = args[0].to_f
          val.ceil
        end
      end

      # FLOOR - Floor value
      class Floor < ScalarFunction
        def initialize
          super(:floor,
            description: "Floor value",
            category: :numeric,
            min_args: 1,
            max_args: 1,
            return_type: :numeric,
            deterministic: true,
            immutable: true
          )
        end

        def execute_scalar(args)
          return nil if args[0].nil?
          val = args[0].to_f
          val.floor
        end
      end

      # ROUND - Round value
      class Round < ScalarFunction
        def initialize
          super(:round,
            description: "Round value",
            category: :numeric,
            min_args: 1,
            max_args: 2,
            return_type: :numeric,
            deterministic: true,
            immutable: true
          )
        end

        def execute_scalar(args)
          return nil if args[0].nil?
          val = args[0].to_f
          decimals = args[1] ? args[1].to_i : 0
          factor = 10 ** decimals
          (val * factor).round / factor.to_f
        end
      end

      # POWER - Power function
      class Power < ScalarFunction
        def initialize
          super(:power,
            description: "Power function",
            category: :numeric,
            min_args: 2,
            max_args: 2,
            return_type: :numeric,
            deterministic: true,
            immutable: true
          )
        end

        def execute_scalar(args)
          return nil if args[0].nil? || args[1].nil?
          base = args[0].to_f
          exponent = args[1].to_f
          base ** exponent
        end
      end

      # SQRT - Square root
      class Sqrt < ScalarFunction
        def initialize
          super(:sqrt,
            description: "Square root",
            category: :numeric,
            min_args: 1,
            max_args: 1,
            return_type: :numeric,
            deterministic: true,
            immutable: true
          )
        end

        def execute_scalar(args)
          return nil if args[0].nil?
          val = args[0].to_f
          Math.sqrt(val)
        end
      end

      # MOD - Modulo
      class Mod < ScalarFunction
        def initialize
          super(:mod,
            description: "Modulo operation",
            category: :numeric,
            min_args: 2,
            max_args: 2,
            return_type: :integer,
            deterministic: true,
            immutable: true
          )
        end

        def execute_scalar(args)
          return nil if args[0].nil? || args[1].nil?
          a = args[0].to_i
          b = args[1].to_i
          b == 0 ? nil : a % b
        end
      end

      # SIGN - Sign of number
      class Sign < ScalarFunction
        def initialize
          super(:sign,
            description: "Sign of number (-1, 0, 1)",
            category: :numeric,
            min_args: 1,
            max_args: 1,
            return_type: :integer,
            deterministic: true,
            immutable: true
          )
        end

        def execute_scalar(args)
          return nil if args[0].nil?
          val = args[0].to_f
          return 1 if val > 0
          return -1 if val < 0
          0
        end
      end

      # LOG - Natural logarithm
      class Log < ScalarFunction
        def initialize
          super(:log,
            description: "Natural logarithm",
            category: :numeric,
            min_args: 1,
            max_args: 1,
            return_type: :numeric,
            deterministic: true,
            immutable: true
          )
        end

        def execute_scalar(args)
          return nil if args[0].nil?
          val = args[0].to_f
          return nil if val <= 0
          Math.log(val)
        end
      end

      # LOG10 - Base-10 logarithm
      class Log10 < ScalarFunction
        def initialize
          super(:log10,
            description: "Base-10 logarithm",
            category: :numeric,
            min_args: 1,
            max_args: 1,
            return_type: :numeric,
            deterministic: true,
            immutable: true
          )
        end

        def execute_scalar(args)
          return nil if args[0].nil?
          val = args[0].to_f
          return nil if val <= 0
          Math.log10(val)
        end
      end

      # SUM - Sum aggregate
      class Sum < AggregateFunction
        def initialize
          super(:sum,
            description: "Sum of values",
            category: :numeric,
            min_args: 1,
            max_args: 1,
            return_type: :numeric
          )
        end

        def execute_aggregate(values)
          values.compact.sum
        end

        def combine(state, value)
          return value if state.nil?
          state + value
        end
      end

      # AVG - Average aggregate
      class Avg < AggregateFunction
        def initialize
          super(:avg,
            description: "Average of values",
            category: :numeric,
            min_args: 1,
            max_args: 1,
            return_type: :numeric
          )
        end

        def execute_aggregate(values)
          return nil if values.empty?
          valid = values.compact
          return nil if valid.empty?
          valid.sum / valid.size.to_f
        end

        def combine(state, value)
          return { sum: value, count: 1 } if state.nil?
          state[:sum] += value
          state[:count] += 1
          state
        end

        def finalize(state)
          return nil if state.nil? || state[:count] == 0
          state[:sum] / state[:count].to_f
        end
      end

      # MIN - Minimum aggregate
      class Min < AggregateFunction
        def initialize
          super(:min,
            description: "Minimum value",
            category: :numeric,
            min_args: 1,
            max_args: 1,
            return_type: :numeric
          )
        end

        def execute_aggregate(values)
          values.compact.min
        end

        def combine(state, value)
          return value if state.nil?
          state < value ? state : value
        end
      end

      # MAX - Maximum aggregate
      class Max < AggregateFunction
        def initialize
          super(:max,
            description: "Maximum value",
            category: :numeric,
            min_args: 1,
            max_args: 1,
            return_type: :numeric
          )
        end

        def execute_aggregate(values)
          values.compact.max
        end

        def combine(state, value)
          return value if state.nil?
          state > value ? state : value
        end
      end

      # COUNT - Count aggregate
      class Count < AggregateFunction
        def initialize
          super(:count,
            description: "Count of values",
            category: :numeric,
            min_args: 1,
            max_args: 1,
            return_type: :integer
          )
        end

        def execute_aggregate(values)
          values.compact.size
        end

        def combine(state, value)
          return 1 if state.nil?
          state + 1
        end
      end
    end
  end
end