# frozen_string_literal: true

module RubyDB
  module Fuzz
    module Generators
      # SchemaGenerator - Generates random database schemas
      class SchemaGenerator
        attr_reader :stats

        DATA_TYPES = [
          :integer, :bigint, :smallint, :float, :decimal,
          :boolean, :text, :varchar, :char, :blob,
          :date, :time, :timestamp, :json, :uuid
        ]

        def initialize(config = {})
          @config = config
          @seed = config[:seed]
          @value_generator = ValueGenerator.new(config)
          @stats = {
            schemas_generated: 0,
            tables_generated: 0,
            columns_generated: 0,
            constraints_generated: 0
          }
          @lock = Mutex.new

          srand(@seed) if @seed
        end

        def generate_schema(options = {})
          @lock.synchronize do
            @stats[:schemas_generated] += 1

            table_count = options[:tables] || rand(1..10)
            schema = {}

            table_count.times do
              table_name = generate_table_name
              columns = generate_columns(options[:columns] || rand(1..20))
              constraints = generate_constraints(columns)

              schema[table_name] = {
                columns: columns,
                constraints: constraints,
                indexes: generate_indexes(columns),
                options: generate_table_options
              }

              @stats[:tables_generated] += 1
              @stats[:columns_generated] += columns.size
              @stats[:constraints_generated] += constraints.size
            end

            schema
          end
        end

        def generate_table_name
          prefixes = ["user", "order", "product", "customer", "employee", "department", "project", "task", "invoice", "payment"]
          suffixes = ["_data", "_info", "_log", "_history", "_archive", "_temp", "_backup", "_main"]

          name = prefixes.sample
          name += suffixes.sample if rand < 0.3
          name += "_" + rand(1000).to_s if rand < 0.2

          name
        end

        def generate_columns(count)
          columns = []
          used_names = Set.new

          # Always include an ID column
          columns << { name: "id", type: :integer, primary_key: true, auto_increment: true }
          used_names.add("id")

          (count - 1).times do
            name = generate_column_name(used_names)
            type = DATA_TYPES.sample
            options = generate_column_options(type)

            columns << { name: name, type: type }.merge(options)
            used_names.add(name)
          end

          columns
        end

        def generate_column_name(used_names)
          prefixes = ["user", "order", "product", "customer", "employee", "department", "project", "task", "invoice", "payment"]
          suffixes = ["id", "name", "date", "time", "status", "type", "code", "value", "amount", "count", "description", "notes"]

          name = prefixes.sample + "_" + suffixes.sample
          while used_names.include?(name)
            name = prefixes.sample + "_" + suffixes.sample + "_" + rand(100).to_s
          end

          name
        end

        def generate_column_options(type)
          options = {}

          # Nullable
          options[:null] = rand < 0.3 if rand < 0.7

          # Default value
          if rand < 0.4
            options[:default] = generate_default_value(type)
          end

          # Type-specific options
          case type
          when :varchar, :char
            options[:limit] = [rand(10..255), 255].min
          when :decimal
            options[:precision] = rand(5..20)
            options[:scale] = rand(0..options[:precision] - 1)
          when :integer, :bigint
            options[:auto_increment] = true if rand < 0.2
          end

          # Unique constraint
          options[:unique] = true if rand < 0.2

          options
        end

        def generate_default_value(type)
          case type
          when :integer, :bigint, :smallint
            rand(1000)
          when :float, :decimal
            rand(1000.0)
          when :boolean
            [true, false].sample
          when :text, :varchar, :char
            "'#{SecureRandom.hex(8)}'"
          when :date
            "'2024-01-01'"
          when :time, :timestamp
            "'2024-01-01 00:00:00'"
          when :uuid
            "'#{SecureRandom.uuid}'"
          else
            nil
          end
        end

        def generate_constraints(columns)
          constraints = []

          # Primary key
          pk_columns = columns.select { |c| c[:primary_key] }
          if pk_columns.any?
            constraints << { type: :primary_key, columns: pk_columns.map { |c| c[:name] } }
          end

          # Unique constraints
          unique_columns = columns.select { |c| c[:unique] }
          if unique_columns.any? && rand < 0.5
            constraints << { type: :unique, columns: unique_columns.map { |c| c[:name] } }
          end

          # Check constraints
          if rand < 0.3
            columns.each do |col|
              if [:integer, :bigint, :smallint].include?(col[:type])
                constraints << { 
                  type: :check, 
                  column: col[:name], 
                  condition: "#{col[:name]} > 0" 
                }
                break
              end
            end
          end

          # Foreign keys (simplified)
          if rand < 0.3 && columns.any? { |c| c[:name].end_with?("_id") }
            fk_col = columns.find { |c| c[:name].end_with?("_id") }
            if fk_col
              constraints << {
                type: :foreign_key,
                column: fk_col[:name],
                reference_table: "users",
                reference_column: "id"
              }
            end
          end

          constraints
        end

        def generate_indexes(columns)
          indexes = []

          # Single column indexes
          columns.each do |col|
            if rand < 0.2 && !col[:primary_key]
              indexes << { columns: [col[:name]], unique: false }
            end
          end

          # Multi-column indexes
          if columns.size > 1 && rand < 0.2
            cols = columns.sample(rand(2..[3, columns.size].min)).map { |c| c[:name] }
            indexes << { columns: cols, unique: false }
          end

          indexes
        end

        def generate_table_options
          options = {}
          options[:if_not_exists] = true if rand < 0.3
          options[:temporary] = true if rand < 0.2
          options
        end

        def generate_ddl(schema)
          @lock.synchronize do
            ddl = []

            schema.each do |table_name, table_def|
              # CREATE TABLE
              columns_sql = table_def[:columns].map do |col|
                sql = "  #{col[:name]} #{col[:type].to_s.upcase}"

                if col[:limit]
                  sql << "(#{col[:limit]})"
                elsif col[:precision] && col[:scale]
                  sql << "(#{col[:precision]}, #{col[:scale]})"
                end

                sql << " PRIMARY KEY" if col[:primary_key]
                sql << " UNIQUE" if col[:unique]
                sql << " NOT NULL" if col[:null] == false
                sql << " DEFAULT #{col[:default]}" if col[:default]
                sql << " AUTO_INCREMENT" if col[:auto_increment]

                sql
              end

              # Constraints
              table_def[:constraints].each do |constraint|
                case constraint[:type]
                when :primary_key
                  columns_sql << "  PRIMARY KEY (#{constraint[:columns].join(', ')})"
                when :unique
                  columns_sql << "  UNIQUE (#{constraint[:columns].join(', ')})"
                when :check
                  columns_sql << "  CHECK (#{constraint[:condition]})"
                when :foreign_key
                  columns_sql << "  FOREIGN KEY (#{constraint[:column]}) REFERENCES #{constraint[:reference_table]}(#{constraint[:reference_column]})"
                end
              end

              ddl << "CREATE TABLE #{table_name} (\n#{columns_sql.join(",\n")}\n);"

              # CREATE INDEX
              table_def[:indexes].each do |index|
                unique = index[:unique] ? "UNIQUE " : ""
                ddl << "CREATE #{unique}INDEX idx_#{table_name}_#{index[:columns].join('_')} ON #{table_name}(#{index[:columns].join(', ')});"
              end
            end

            ddl.join("\n")
          end
        end

        def stats
          @lock.synchronize do
            @stats.merge({
              data_types: DATA_TYPES.size,
              seed: @seed
            })
          end
        end
      end
    end
  end
end