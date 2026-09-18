# frozen_string_literal: true

module RubyDB
  module Execution
    class OperatorSelection
      def initialize(engine)
        @engine = engine
      end

      def choose_scan(plan)
        return plan unless plan.type == :select

        table_name = plan.table_name
        return plan.set_scan_type(:sequential) unless table_name

        index = matching_index(plan)
        index ? plan.set_scan_type(:index, index) : plan.set_scan_type(:sequential)
      end

      def physical_operator(plan)
        return :index_scan if plan.scan_type == :index
        return :sequential_scan if plan.scan_type == :sequential
        return :hash_join if plan.joins&.any?

        plan.type
      end

      private

      def matching_index(plan)
        return nil unless @engine.respond_to?(:index_manager) && plan.predicate

        columns = predicate_columns(plan.predicate).map(&:to_s)
        @engine.index_manager.get_indexes_for_table(plan.table_name).find do |index|
          index.columns.any? { |column| columns.include?(column.to_s) }
        end
      rescue
        nil
      end

      def predicate_columns(predicate)
        case predicate
        when Predicate::Comparison
          [predicate.left.respond_to?(:name) ? predicate.left.name : nil].compact
        when Predicate::And, Predicate::Or
          predicate_columns(predicate.left) + predicate_columns(predicate.right)
        when Predicate::Not
          predicate_columns(predicate.operand)
        when Predicate::Between, Predicate::In, Predicate::IsNull, Predicate::Like
          [predicate.expression.respond_to?(:name) ? predicate.expression.name : nil].compact
        else
          []
        end
      end
    end
  end
end
