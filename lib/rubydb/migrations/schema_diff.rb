# frozen_string_literal: true

require "monitor"

module RubyDB
  module Migrations
    # SchemaDiff - Compares schemas and generates migrations
    class SchemaDiff
      attr_reader :stats

      def initialize(engine, config = {})
        @engine = engine
        @config = config
        @stats = {
          diffs_computed: 0,
          migrations_generated: 0,
          tables_added: 0,
          tables_removed: 0,
          columns_added: 0,
          columns_removed: 0,
          columns_changed: 0
        }
        @lock = Monitor.new
      end

      def diff(source_schema, target_schema)
        @lock.synchronize do
          @stats[:diffs_computed] += 1

          result = {
            added_tables: [],
            removed_tables: [],
            changed_tables: [],
            added_columns: [],
            removed_columns: [],
            changed_columns: [],
            warnings: [],
            target_schema: target_schema
          }

          # Compare tables
          source_tables = source_schema.keys
          target_tables = target_schema.keys

          added = target_tables - source_tables
          removed = source_tables - target_tables
          common = source_tables & target_tables

          result[:added_tables] = added
          result[:removed_tables] = removed

          # Compare common tables
          common.each do |table|
            source_cols = source_schema[table] || {}
            target_cols = target_schema[table] || {}

            # Find added/removed columns
            added_cols = target_cols.keys - source_cols.keys
            removed_cols = source_cols.keys - target_cols.keys
            common_cols = source_cols.keys & target_cols.keys

            result[:added_columns] += added_cols.map { |c| { table: table, column: c } }
            result[:removed_columns] += removed_cols.map { |c| { table: table, column: c } }

            # Find changed columns
            common_cols.each do |col|
              if source_cols[col] != target_cols[col]
                result[:changed_columns] << {
                  table: table,
                  column: col,
                  old_type: source_cols[col],
                  new_type: target_cols[col]
                }
              end
            end
          end

          result
        end
      end

      def generate_migration(source_schema, target_schema, options = {})
        @lock.synchronize do
          diff_result = diff(source_schema, target_schema)
          @stats[:migrations_generated] += 1

          @stats[:tables_added] += diff_result[:added_tables].size
          @stats[:tables_removed] += diff_result[:removed_tables].size
          @stats[:columns_added] += diff_result[:added_columns].size
          @stats[:columns_removed] += diff_result[:removed_columns].size
          @stats[:columns_changed] += diff_result[:changed_columns].size

          migration_name = options[:name] || "auto_migration_#{Time.now.strftime('%Y%m%d%H%M%S')}"
          migration_code = generate_migration_code(diff_result, migration_name)

          {
            success: true,
            migration_name: migration_name,
            code: migration_code,
            diff: diff_result,
            summary: {
              tables_added: diff_result[:added_tables].size,
              tables_removed: diff_result[:removed_tables].size,
              columns_added: diff_result[:added_columns].size,
              columns_removed: diff_result[:removed_columns].size,
              columns_changed: diff_result[:changed_columns].size
            }
          }
        end
      end

      def diff_to_sql(source_schema, target_schema)
        @lock.synchronize do
          diff_result = diff(source_schema, target_schema)
          sql = []

          # Tables to create
          diff_result[:added_tables].each do |table|
            columns = target_schema[table] || {}
            col_defs = columns.map { |name, type| "  #{name} #{type}" }.join(",\n")
            sql << "CREATE TABLE #{table} (\n#{col_defs}\n);"
          end

          # Tables to drop
          diff_result[:removed_tables].each do |table|
            sql << "DROP TABLE #{table};"
          end

          # Columns to add
          diff_result[:added_columns].each do |col|
            sql << "ALTER TABLE #{col[:table]} ADD COLUMN #{col[:column]} #{target_schema[col[:table]][col[:column]]};"
          end

          # Columns to remove
          diff_result[:removed_columns].each do |col|
            sql << "ALTER TABLE #{col[:table]} DROP COLUMN #{col[:column]};"
          end

          # Columns to change
          diff_result[:changed_columns].each do |col|
            sql << "ALTER TABLE #{col[:table]} ALTER COLUMN #{col[:column]} TYPE #{col[:new_type]};"
          end

          sql.join("\n")
        end
      end

      def stats
        @lock.synchronize do
          @stats.merge({
            diff_enabled: true
          })
        end
      end

      private

      def generate_migration_code(diff_result, name)
        # Generate Ruby migration code
        code = []
        code << "# frozen_string_literal: true"
        code << ""
        code << "# Migration: #{name}"
        code << "# Generated: #{Time.now.iso8601}"
        code << ""
        code << "migration = Migration.new('#{Time.now.strftime('%Y%m%d%H%M%S')}', '#{name}')"
        code << ""
        code << "migration.up do |engine|"

        # Tables to create
        diff_result[:added_tables].each do |table|
          code << "  engine.create_table('#{table}') do |t|"
          (diff_result[:target_schema] || {})[table]&.each do |col_name, col_type|
            code << "    t.column('#{col_name}', '#{col_type}')"
          end
          code << "  end"
        end

        # Tables to drop
        diff_result[:removed_tables].each do |table|
          code << "  engine.drop_table('#{table}')"
        end

        # Columns to add
        diff_result[:added_columns].each do |col|
          code << "  engine.add_column('#{col[:table]}', '#{col[:column]}', '#{diff_result[:target_schema][col[:table]][col[:column]]}')"
        end

        # Columns to remove
        diff_result[:removed_columns].each do |col|
          code << "  engine.remove_column('#{col[:table]}', '#{col[:column]}')"
        end

        # Columns to change
        diff_result[:changed_columns].each do |col|
          code << "  engine.change_column('#{col[:table]}', '#{col[:column]}', '#{col[:new_type]}')"
        end

        code << "end"
        code << ""
        code << "migration.down do |engine|"
        code << "  # Rollback changes (reverse order)"
        code << "end"
        code << ""
        code << "migration"

        code.join("\n")
      end
    end
  end
end
