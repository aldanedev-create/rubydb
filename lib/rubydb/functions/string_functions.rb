# frozen_string_literal: true

require "digest"
require "base64"

module RubyDB
  module Functions
    # StringFunctions - All string-related functions
    class StringFunctions
      # LOWER - Convert string to lowercase
      class Lower < ScalarFunction
        def initialize
          super(:lower,
            description: "Convert string to lowercase",
            category: :string,
            min_args: 1,
            max_args: 1,
            return_type: :text,
            deterministic: true,
            immutable: true
          )
        end

        def execute_scalar(args)
          return nil if args[0].nil?
          args[0].to_s.downcase
        end
      end

      # UPPER - Convert string to uppercase
      class Upper < ScalarFunction
        def initialize
          super(:upper,
            description: "Convert string to uppercase",
            category: :string,
            min_args: 1,
            max_args: 1,
            return_type: :text,
            deterministic: true,
            immutable: true
          )
        end

        def execute_scalar(args)
          return nil if args[0].nil?
          args[0].to_s.upcase
        end
      end

      # LENGTH - Get string length
      class Length < ScalarFunction
        def initialize
          super(:length,
            description: "Get string length",
            category: :string,
            min_args: 1,
            max_args: 1,
            return_type: :integer,
            deterministic: true,
            immutable: true
          )
        end

        def execute_scalar(args)
          return nil if args[0].nil?
          args[0].to_s.length
        end
      end

      # SUBSTR - Extract substring
      class Substr < ScalarFunction
        def initialize
          super(:substr,
            description: "Extract substring",
            category: :string,
            min_args: 2,
            max_args: 3,
            return_type: :text,
            deterministic: true,
            immutable: true
          )
        end

        def execute_scalar(args)
          return nil if args[0].nil? || args[1].nil?

          str = args[0].to_s
          start_pos = args[1].to_i
          length = args[2] ? args[2].to_i : str.length

          start_pos -= 1 if start_pos > 0
          str[start_pos, length]
        end
      end

      # CONCAT - Concatenate strings
      class Concat < ScalarFunction
        def initialize
          super(:concat,
            description: "Concatenate strings",
            category: :string,
            min_args: 1,
            max_args: -1,
            return_type: :text,
            deterministic: true,
            immutable: true
          )
        end

        def execute_scalar(args)
          args.map { |a| a.to_s }.join
        end
      end

      # TRIM - Remove whitespace
      class Trim < ScalarFunction
        def initialize
          super(:trim,
            description: "Remove leading and trailing whitespace",
            category: :string,
            min_args: 1,
            max_args: 1,
            return_type: :text,
            deterministic: true,
            immutable: true
          )
        end

        def execute_scalar(args)
          return nil if args[0].nil?
          args[0].to_s.strip
        end
      end

      # LTRIM - Remove leading whitespace
      class Ltrim < ScalarFunction
        def initialize
          super(:ltrim,
            description: "Remove leading whitespace",
            category: :string,
            min_args: 1,
            max_args: 1,
            return_type: :text,
            deterministic: true,
            immutable: true
          )
        end

        def execute_scalar(args)
          return nil if args[0].nil?
          args[0].to_s.lstrip
        end
      end

      # RTRIM - Remove trailing whitespace
      class Rtrim < ScalarFunction
        def initialize
          super(:rtrim,
            description: "Remove trailing whitespace",
            category: :string,
            min_args: 1,
            max_args: 1,
            return_type: :text,
            deterministic: true,
            immutable: true
          )
        end

        def execute_scalar(args)
          return nil if args[0].nil?
          args[0].to_s.rstrip
        end
      end

      # REPLACE - Replace substring
      class Replace < ScalarFunction
        def initialize
          super(:replace,
            description: "Replace substring",
            category: :string,
            min_args: 3,
            max_args: 3,
            return_type: :text,
            deterministic: true,
            immutable: true
          )
        end

        def execute_scalar(args)
          return nil if args[0].nil?
          str = args[0].to_s
          from = args[1].to_s
          to = args[2].to_s
          str.gsub(from, to)
        end
      end

      # POSITION - Find position of substring
      class Position < ScalarFunction
        def initialize
          super(:position,
            description: "Find position of substring",
            category: :string,
            min_args: 2,
            max_args: 2,
            return_type: :integer,
            deterministic: true,
            immutable: true
          )
        end

        def execute_scalar(args)
          return nil if args[0].nil? || args[1].nil?
          substr = args[0].to_s
          str = args[1].to_s
          pos = str.index(substr)
          pos ? pos + 1 : 0
        end
      end

      # SPLIT_PART - Split string and get part
      class SplitPart < ScalarFunction
        def initialize
          super(:split_part,
            description: "Split string and get part",
            category: :string,
            min_args: 3,
            max_args: 3,
            return_type: :text,
            deterministic: true,
            immutable: true
          )
        end

        def execute_scalar(args)
          return nil if args[0].nil?
          str = args[0].to_s
          delimiter = args[1].to_s
          part = args[2].to_i

          parts = str.split(delimiter)
          return nil if part <= 0 || part > parts.size
          parts[part - 1]
        end
      end

      # MD5 - Calculate MD5 hash
      class MD5 < ScalarFunction
        def initialize
          super(:md5,
            description: "Calculate MD5 hash",
            category: :string,
            min_args: 1,
            max_args: 1,
            return_type: :text,
            deterministic: true,
            immutable: true
          )
        end

        def execute_scalar(args)
          return nil if args[0].nil?
          Digest::MD5.hexdigest(args[0].to_s)
        end
      end

      # SHA256 - Calculate SHA256 hash
      class SHA256 < ScalarFunction
        def initialize
          super(:sha256,
            description: "Calculate SHA256 hash",
            category: :string,
            min_args: 1,
            max_args: 1,
            return_type: :text,
            deterministic: true,
            immutable: true
          )
        end

        def execute_scalar(args)
          return nil if args[0].nil?
          Digest::SHA256.hexdigest(args[0].to_s)
        end
      end

      # REVERSE - Reverse string
      class Reverse < ScalarFunction
        def initialize
          super(:reverse,
            description: "Reverse string",
            category: :string,
            min_args: 1,
            max_args: 1,
            return_type: :text,
            deterministic: true,
            immutable: true
          )
        end

        def execute_scalar(args)
          return nil if args[0].nil?
          args[0].to_s.reverse
        end
      end

      # LEFT - Get leftmost characters
      class Left < ScalarFunction
        def initialize
          super(:left,
            description: "Get leftmost characters",
            category: :string,
            min_args: 2,
            max_args: 2,
            return_type: :text,
            deterministic: true,
            immutable: true
          )
        end

        def execute_scalar(args)
          return nil if args[0].nil? || args[1].nil?
          str = args[0].to_s
          count = args[1].to_i
          str[0, count]
        end
      end

      # RIGHT - Get rightmost characters
      class Right < ScalarFunction
        def initialize
          super(:right,
            description: "Get rightmost characters",
            category: :string,
            min_args: 2,
            max_args: 2,
            return_type: :text,
            deterministic: true,
            immutable: true
          )
        end

        def execute_scalar(args)
          return nil if args[0].nil? || args[1].nil?
          str = args[0].to_s
          count = args[1].to_i
          str[-count, count] || str
        end
      end

      # STRING_AGG - String aggregate
      class StringAgg < AggregateFunction
        def initialize
          super(:string_agg,
            description: "Aggregate strings with delimiter",
            category: :string,
            min_args: 2,
            max_args: 2,
            return_type: :text
          )
        end

        def execute_aggregate(values)
          return nil if values.empty?
          delimiter = values.last
          values = values[0...-1]
          values.compact.join(delimiter.to_s)
        end

        def combine(state, value)
          return value if state.nil?
          "#{state}#{delimiter}#{value}"
        end

        private

        def delimiter
          @delimiter ||= ","
        end
      end
    end
  end
end