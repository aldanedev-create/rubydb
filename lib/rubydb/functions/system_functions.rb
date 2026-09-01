# frozen_string_literal: true

module RubyDB
  module Functions
    # SystemFunctions - All system-related functions
    class SystemFunctions
      # VERSION - Database version
      class Version < ScalarFunction
        def initialize
          super(:version,
            description: "Database version",
            category: :system,
            min_args: 0,
            max_args: 0,
            return_type: :text,
            deterministic: false,
            immutable: false
          )
        end

        def execute_scalar(args)
          "RubyDB #{RubyDB::VERSION}"
        end
      end

      # DB_NAME - Current database name
      class DbName < ScalarFunction
        def initialize
          super(:db_name,
            description: "Current database name",
            category: :system,
            min_args: 0,
            max_args: 0,
            return_type: :text,
            deterministic: false,
            immutable: false
          )
        end

        def execute_scalar(args)
          @engine.current_database_name if @engine.respond_to?(:current_database_name)
        end
      end

      # USER - Current user
      class User < ScalarFunction
        def initialize
          super(:user,
            description: "Current user",
            category: :system,
            min_args: 0,
            max_args: 0,
            return_type: :text,
            deterministic: false,
            immutable: false
          )
        end

        def execute_scalar(args)
          ENV["USER"] || ENV["USERNAME"] || "unknown"
        end
      end

      # PG_BACKEND_PID - Current process ID
      class BackendPid < ScalarFunction
        def initialize
          super(:pg_backend_pid,
            description: "Current process ID",
            category: :system,
            min_args: 0,
            max_args: 0,
            return_type: :integer,
            deterministic: false,
            immutable: false
          )
        end

        def execute_scalar(args)
          Process.pid
        end
      end

      # COALESCE - Return first non-null value
      class Coalesce < ScalarFunction
        def initialize
          super(:coalesce,
            description: "Return first non-null value",
            category: :system,
            min_args: 1,
            max_args: -1,
            return_type: :text,
            deterministic: true,
            immutable: true
          )
        end

        def execute_scalar(args)
          args.find { |a| !a.nil? }
        end
      end

      # NULLIF - Return null if values equal
      class NullIf < ScalarFunction
        def initialize
          super(:nullif,
            description: "Return null if values equal",
            category: :system,
            min_args: 2,
            max_args: 2,
            return_type: :text,
            deterministic: true,
            immutable: true
          )
        end

        def execute_scalar(args)
          return nil if args[0].nil? || args[1].nil?
          args[0] == args[1] ? nil : args[0]
        end
      end

      # CAST - Cast value to type
      class Cast < ScalarFunction
        def initialize
          super(:cast,
            description: "Cast value to type",
            category: :system,
            min_args: 2,
            max_args: 2,
            return_type: :text,
            deterministic: true,
            immutable: true
          )
        end

        def execute_scalar(args)
          return nil if args[0].nil? || args[1].nil?

          value = args[0]
          target_type = args[1].to_s.downcase

          case target_type
          when "integer", "int"
            value.to_i
          when "bigint"
            value.to_i
          when "smallint"
            value.to_i
          when "float", "numeric", "decimal"
            value.to_f
          when "boolean", "bool"
            value == true || value.to_s.downcase == "true" || value.to_s.downcase == "t" || value.to_i == 1
          when "text", "string", "varchar"
            value.to_s
          when "date"
            Date.parse(value.to_s) rescue nil
          when "timestamp", "datetime"
            Time.parse(value.to_s) rescue nil
          when "json"
            JSON.parse(value.to_s) rescue {}
          else
            value
          end
        end
      end

      # GREATEST - Return greatest value
      class Greatest < ScalarFunction
        def initialize
          super(:greatest,
            description: "Return greatest value",
            category: :system,
            min_args: 2,
            max_args: -1,
            return_type: :text,
            deterministic: true,
            immutable: true
          )
        end

        def execute_scalar(args)
          args.compact.max
        end
      end

      # LEAST - Return least value
      class Least < ScalarFunction
        def initialize
          super(:least,
            description: "Return least value",
            category: :system,
            min_args: 2,
            max_args: -1,
            return_type: :text,
            deterministic: true,
            immutable: true
          )
        end

        def execute_scalar(args)
          args.compact.min
        end
      end

      # RANDOM - Generate random number
      class Random < ScalarFunction
        def initialize
          super(:random,
            description: "Generate random number between 0 and 1",
            category: :system,
            min_args: 0,
            max_args: 0,
            return_type: :float,
            deterministic: false,
            immutable: false
          )
        end

        def execute_scalar(args)
          rand
        end
      end

      # UUID_GENERATE - Generate UUID
      class UUIDGenerate < ScalarFunction
        require "securerandom"

        def initialize
          super(:uuid_generate,
            description: "Generate UUID",
            category: :system,
            min_args: 0,
            max_args: 0,
            return_type: :uuid,
            deterministic: false,
            immutable: false
          )
        end

        def execute_scalar(args)
          SecureRandom.uuid
        end
      end
    end
  end
end