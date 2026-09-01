# frozen_string_literal: true

module RubyDB
  module Fuzz
    module Generators
      # SQLGenerator - Generates random SQL statements
      class SQLGenerator
        attr_reader :stats

        def initialize(config = {})
          @config = config
          @seed = config[:seed]
          @schema_generator = SchemaGenerator.new(config)
          @value_generator = ValueGenerator.new(config)
          @schema = nil
          @stats = {
            sql_generated: 0,
            by_type: Hash.new(0)
          }
          @lock = Mutex.new

          srand(@seed) if @seed
        end

        def generate_sql(options = {})
          @lock.synchronize do
            @stats[:sql_generated] += 1

            # Generate schema if not provided
            @schema ||= @schema_generator.generate_schema

            # Choose statement type
            statement_type = options[:type] || choose_statement_type

            @stats[:by_type][statement_type] += 1

            case statement_type
            when :select
              generate_select
            when :insert
              generate_insert
            when :update
              generate_update
            when :delete
              generate_delete
            when :create_table
              generate_create_table
            when :drop_table
              generate_drop_table
            when :alter_table
              generate_alter_table
            when :begin
              generate_begin
            when :commit
              generate_commit
            when :rollback
              generate_rollback
            when :explain
              generate_explain
            else
              generate_select
            end
          end
        end

        def generate_batch(count, options = {})
          @lock.synchronize do
            count.times.map { generate_sql(options) }
          end
        end

        def generate_mixed_batch(count)
          @lock.synchronize do
            types = [:select, :insert, :update, :delete, :create_table, :drop_table, :alter_table, :begin, :commit, :rollback]
            count.times.map do
              type = types.sample
              generate_sql(type: type)
            end
          end
        end

        private

        def choose_statement_type
          types = [:select] * 10 + [:insert] * 5 + [:update] * 4 + [:delete] * 3 + 
                  [:create_table] * 2 + [:drop_table] * 1 + [:alter_table] * 1 +
                  [:begin] * 2 + [:commit] * 2 + [:rollback] * 2 + [:explain] * 1
          types.sample
        end

        def generate_select
          table = get_random_table
          columns = get_table_columns(table)

          selected_columns = if rand < 0.3
            "*"
          else
            columns.sample(rand(1..[5, columns.size].min)).join(", ")
          end

          sql = "SELECT #{selected_columns} FROM #{table}"

          # WHERE clause
          if rand < 0.6
            where_conditions = generate_where_conditions(table)
            sql << " WHERE #{where_conditions}" unless where_conditions.empty?
          end

          # GROUP BY
          if rand < 0.2
            group_columns = columns.sample(rand(1..2))
            sql << " GROUP BY #{group_columns.join(', ')}"
          end

          # HAVING
          if rand < 0.1 && sql.include?("GROUP BY")
            sql << " HAVING COUNT(*) > #{rand(1..10)}"
          end

          # ORDER BY
          if rand < 0.4
            order_columns = columns.sample(rand(1..2))
            directions = ["ASC", "DESC"]
            sql << " ORDER BY #{order_columns.map { |c| "#{c} #{directions.sample}" }.join(', ')}"
          end

          # LIMIT
          if rand < 0.3
            sql << " LIMIT #{rand(1..100)}"
            sql << " OFFSET #{rand(0..50)}" if rand < 0.3
          end

          sql
        end

        def generate_insert
          table = get_random_table
          columns = get_table_columns(table)

          # Generate values
          values = columns.map do |col|
            type = get_column_type(table, col)
            @value_generator.generate(type)
          end

          sql = "INSERT INTO #{table} (#{columns.join(', ')}) VALUES (#{values.join(', ')})"

          # Insert multiple rows
          if rand < 0.2
            sql << ", "
            2.times do
              values = columns.map do |col|
                type = get_column_type(table, col)
                @value_generator.generate(type)
              end
              sql << "(#{values.join(', ')})"
              sql << ", " unless values == columns.last
            end
          end

          sql
        end

        def generate_update
          table = get_random_table
          columns = get_table_columns(table)

          # Set clause
          set_columns = columns.sample(rand(1..[3, columns.size].min))
          set_clause = set_columns.map do |col|
            type = get_column_type(table, col)
            value = @value_generator.generate(type)
            "#{col} = #{value}"
          end.join(", ")

          sql = "UPDATE #{table} SET #{set_clause}"

          # WHERE clause
          if rand < 0.7
            where_conditions = generate_where_conditions(table)
            sql << " WHERE #{where_conditions}" unless where_conditions.empty?
          end

          sql
        end

        def generate_delete
          table = get_random_table
          sql = "DELETE FROM #{table}"

          if rand < 0.7
            where_conditions = generate_where_conditions(table)
            sql << " WHERE #{where_conditions}" unless where_conditions.empty?
          end

          sql
        end

        def generate_create_table
          schema = @schema_generator.generate_schema(tables: 1)
          table_name = schema.keys.first
          table_def = schema[table_name]

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

          sql = "CREATE TABLE #{table_name} (\n#{columns_sql.join(",\n")}\n)"
          sql << " IF NOT EXISTS" if rand < 0.3
          sql
        end

        def generate_drop_table
          table = get_random_table
          sql = "DROP TABLE #{table}"
          sql << " IF EXISTS" if rand < 0.3
          sql << " CASCADE" if rand < 0.2
          sql
        end

        def generate_alter_table
          table = get_random_table
          columns = get_table_columns(table)

          operations = [
            "ADD COLUMN new_column INTEGER",
            "DROP COLUMN #{columns.sample}",
            "RENAME COLUMN #{columns.sample} TO renamed_column"
          ]

          if rand < 0.2
            operations << "RENAME TO #{table}_renamed"
          end

          op = operations.sample
          "ALTER TABLE #{table} #{op}"
        end

        def generate_begin
          ["BEGIN", "BEGIN TRANSACTION", "START TRANSACTION"].sample
        end

        def generate_commit
          ["COMMIT", "COMMIT TRANSACTION", "END TRANSACTION"].sample
        end

        def generate_rollback
          ["ROLLBACK", "ROLLBACK TRANSACTION"].sample
        end

        def generate_explain
          sql = generate_sql(type: :select)
          "EXPLAIN #{sql}"
        end

        def generate_where_conditions(table)
          columns = get_table_columns(table)
          conditions = []

          # 1-3 conditions
          rand(1..3).times do
            col = columns.sample
            type = get_column_type(table, col)

            case type
            when :integer, :bigint, :smallint, :float, :decimal
              op = ["=", "!=", ">", "<", ">=", "<="].sample
              value = @value_generator.generate(type)
              conditions << "#{col} #{op} #{value}"
            when :text, :varchar, :char
              op = ["=", "!=", "LIKE", "ILIKE"].sample
              if op == "LIKE" || op == "ILIKE"
                value = "'%#{SecureRandom.hex(4)}%'"
              else
                value = "'#{SecureRandom.hex(8)}'"
              end
              conditions << "#{col} #{op} #{value}"
            when :boolean
              conditions << "#{col} = #{[true, false].sample}"
            when :date, :time, :timestamp
              op = ["=", "!=", ">", "<", ">=", "<="].sample
              value = "'#{@value_generator.generate(type).iso8601}'"
              conditions << "#{col} #{op} #{value}"
            else
              op = ["=", "!="].sample
              value = @value_generator.generate(type)
              conditions << "#{col} #{op} #{value}"
            end
          end

          # AND/OR between conditions
          if conditions.size > 1
            separator = rand < 0.7 ? " AND " : " OR "
            conditions.join(separator)
          else
            conditions.first
          end
        end

        def get_random_table
          return "users" unless @schema && @schema.any?
          @schema.keys.sample
        end

        def get_table_columns(table)
          return ["id", "name", "age"] unless @schema && @schema[table]
          @schema[table][:columns].map { |c| c[:name] }
        end

        def get_column_type(table, column)
          return :text unless @schema && @schema[table]
          col_def = @schema[table][:columns].find { |c| c[:name] == column }
          col_def ? col_def[:type] : :text
        end

        def stats
          @lock.synchronize do
            @stats.merge({
              seed: @seed,
              schema_tables: @schema ? @schema.size : 0,
              total_generated: @stats[:sql_generated]
            })
          end
        end
      end
    end
  end
end