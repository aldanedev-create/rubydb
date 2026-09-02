# frozen_string_literal: true

module RubyDB
  module Branching
    # Diff - Compares branches
    class Diff
      attr_reader :stats

      # Diff types
      DIFF_TABLE = :table
      DIFF_SCHEMA = :schema
      DIFF_DATA = :data
      DIFF_ALL = :all

      def initialize(engine, branch_manager, config = {})
        @engine = engine
        @branch_manager = branch_manager
        @config = config
        @stats = {
          diffs: 0,
          diff_time_ms: 0,
          avg_diff_time_ms: 0,
          tables_diffed: 0,
          rows_diffed: 0
        }
        @lock = Mutex.new
        @diff_cache = {}
      end

      def diff(branch_a, branch_b, options = {})
        @lock.synchronize do
          start_time = Time.now
          @stats[:diffs] += 1

          a = @branch_manager.get_branch(branch_a)
          b = @branch_manager.get_branch(branch_b)

          unless a
            return { success: false, error: "Branch '#{branch_a}' not found" }
          end

          unless b
            return { success: false, error: "Branch '#{branch_b}' not found" }
          end

          diff_type = options[:type] || DIFF_ALL
          tables = options[:tables]

          result = case diff_type
          when DIFF_TABLE
            diff_tables(a, b, tables)
          when DIFF_SCHEMA
            diff_schemas(a, b, tables)
          when DIFF_DATA
            diff_data(a, b, tables)
          else
            diff_all(a, b, tables)
          end

          elapsed_ms = (Time.now - start_time) * 1000
          @stats[:diff_time_ms] += elapsed_ms
          @stats[:avg_diff_time_ms] = @stats[:diff_time_ms] / @stats[:diffs]
          @stats[:tables_diffed] += result[:tables]&.size || 0
          @stats[:rows_diffed] += result[:rows]&.size || 0

          result.merge(elapsed_ms: elapsed_ms)
        end
      end

      def diff_tables(branch_a, branch_b, tables = nil)
        compare_changes(branch_a, branch_b, tables, :tables)
      end

      def diff_schemas(branch_a, branch_b, tables = nil)
        compare_changes(branch_a, branch_b, tables, :schemas)
      end

      def diff_data(branch_a, branch_b, tables = nil)
        compare_changes(branch_a, branch_b, tables, :data)
      end

      def diff_all(branch_a, branch_b, tables = nil)
        compare_changes(branch_a, branch_b, tables, :all)
      end

      def diff_table(branch_a, branch_b, table)
        @lock.synchronize do
          cache_key = "#{branch_a}_#{branch_b}_#{table}"
          if @diff_cache.key?(cache_key)
            return @diff_cache[cache_key]
          end

          result = perform_table_diff(branch_a, branch_b, table)
          @diff_cache[cache_key] = result if result[:success]

          result
        end
      end

      def clear_cache
        @lock.synchronize do
          @diff_cache.clear
        end
      end

      def stats
        @lock.synchronize do
          @stats.merge({
            cache_size: @diff_cache.size
          })
        end
      end

      private

      def perform_table_diff(branch_a, branch_b, table)
        compare_changes(branch_a, branch_b, [table], :table).merge(table: table)
      end

      def compare_changes(branch_a, branch_b, tables, type)
        a = branch_a.respond_to?(:logical_changes) ? branch_a : @branch_manager.get_branch(branch_a)
        b = branch_b.respond_to?(:logical_changes) ? branch_b : @branch_manager.get_branch(branch_b)
        return { success: false, error: "Branch not found: #{branch_a.inspect}, #{branch_b.inspect}" } unless a && b

        filter = tables && Array(tables).map(&:to_s)
        changes_a = a.respond_to?(:logical_changes) ? a.logical_changes : a.changes
        changes_b = b.respond_to?(:logical_changes) ? b.logical_changes : b.changes
        changes_a = changes_a.select { |change| filter.include?(change[:table].to_s) } if filter
        changes_b = changes_b.select { |change| filter.include?(change[:table].to_s) } if filter
        added = changes_b.reject { |change| changes_a.include?(change) }
        removed = changes_a.reject { |change| changes_b.include?(change) }
        { success: true, type: type, tables: (changes_a + changes_b).map { |c| c[:table] }.compact.uniq,
          rows: { added: added, removed: removed }, changes: { added: added, removed: removed } }
      end

    end
  end
end
