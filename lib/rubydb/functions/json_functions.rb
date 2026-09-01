# frozen_string_literal: true

require "json"

module RubyDB
  module Functions
    # JsonFunctions - All JSON-related functions
    class JsonFunctions
      # JSON_EXTRACT - Extract value from JSON
      class JsonExtract < ScalarFunction
        def initialize
          super(:json_extract,
            description: "Extract value from JSON",
            category: :json,
            min_args: 2,
            max_args: 2,
            return_type: :text,
            deterministic: true,
            immutable: true
          )
        end

        def execute_scalar(args)
          return nil if args[0].nil? || args[1].nil?

          json = parse_json(args[0])
          path = args[1].to_s

          result = json
          path.split(".").each do |key|
            break unless result.is_a?(Hash) || result.is_a?(Array)

            if result.is_a?(Hash)
              result = result[key]
            elsif result.is_a?(Array)
              idx = key.to_i
              result = result[idx] if idx >= 0 && idx < result.size
            end
          end

          result.is_a?(String) ? result : result.to_json
        end

        private

        def parse_json(value)
          if value.is_a?(Hash) || value.is_a?(Array)
            value
          elsif value.is_a?(String)
            JSON.parse(value) rescue {}
          else
            {}
          end
        end
      end

      # JSON_ARRAY - Create JSON array
      class JsonArray < ScalarFunction
        def initialize
          super(:json_array,
            description: "Create JSON array",
            category: :json,
            min_args: 0,
            max_args: -1,
            return_type: :json,
            deterministic: true,
            immutable: true
          )
        end

        def execute_scalar(args)
          args.map { |a| a.is_a?(String) ? a : a.to_s }.to_json
        end
      end

      # JSON_OBJECT - Create JSON object
      class JsonObject < ScalarFunction
        def initialize
          super(:json_object,
            description: "Create JSON object",
            category: :json,
            min_args: 2,
            max_args: -1,
            return_type: :json,
            deterministic: true,
            immutable: true
          )
        end

        def execute_scalar(args)
          result = {}
          i = 0
          while i < args.size - 1
            key = args[i].to_s
            value = args[i + 1]
            result[key] = value.is_a?(String) ? value : value.to_s
            i += 2
          end
          result.to_json
        end
      end

      # JSON_ARRAY_LENGTH - Get JSON array length
      class JsonArrayLength < ScalarFunction
        def initialize
          super(:json_array_length,
            description: "Get JSON array length",
            category: :json,
            min_args: 1,
            max_args: 1,
            return_type: :integer,
            deterministic: true,
            immutable: true
          )
        end

        def execute_scalar(args)
          return nil if args[0].nil?

          json = parse_json(args[0])
          json.is_a?(Array) ? json.size : 0
        end

        private

        def parse_json(value)
          if value.is_a?(Hash) || value.is_a?(Array)
            value
          elsif value.is_a?(String)
            JSON.parse(value) rescue {}
          else
            {}
          end
        end
      end

      # JSON_TYPE - Get JSON value type
      class JsonType < ScalarFunction
        def initialize
          super(:json_type,
            description: "Get JSON value type",
            category: :json,
            min_args: 1,
            max_args: 1,
            return_type: :text,
            deterministic: true,
            immutable: true
          )
        end

        def execute_scalar(args)
          return nil if args[0].nil?

          json = parse_json(args[0])
          case json
          when Hash then "object"
          when Array then "array"
          when String then "string"
          when Integer then "integer"
          when Float then "number"
          when true, false then "boolean"
          when nil then "null"
          else "unknown"
          end
        end

        private

        def parse_json(value)
          if value.is_a?(Hash) || value.is_a?(Array)
            value
          elsif value.is_a?(String)
            JSON.parse(value) rescue {}
          else
            {}
          end
        end
      end

      # JSON_KEYS - Get JSON object keys
      class JsonKeys < ScalarFunction
        def initialize
          super(:json_keys,
            description: "Get JSON object keys",
            category: :json,
            min_args: 1,
            max_args: 1,
            return_type: :json,
            deterministic: true,
            immutable: true
          )
        end

        def execute_scalar(args)
          return nil if args[0].nil?

          json = parse_json(args[0])
          json.is_a?(Hash) ? json.keys.to_json : [].to_json
        end

        private

        def parse_json(value)
          if value.is_a?(Hash) || value.is_a?(Array)
            value
          elsif value.is_a?(String)
            JSON.parse(value) rescue {}
          else
            {}
          end
        end
      end
    end
  end
end