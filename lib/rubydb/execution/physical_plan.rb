# frozen_string_literal: true

module RubyDB
  module Execution
    # A compact description of the physical choices made for a logical Plan.
    # Plan remains the executable object; this value is for explainability,
    # cache keys, and the Ruby/Go dispatch boundary.
    class PhysicalPlan
      attr_reader :logical_plan, :operator, :estimated_cost, :estimated_rows, :properties

      def self.from(plan, operator: nil, estimated_cost: nil, estimated_rows: nil, properties: {})
        new(
          plan,
          operator: operator || default_operator(plan),
          estimated_cost: estimated_cost.nil? ? plan.estimated_cost : estimated_cost,
          estimated_rows: estimated_rows.nil? ? plan.estimated_rows : estimated_rows,
          properties: properties
        )
      end

      def self.default_operator(plan)
        return :index_scan if plan.respond_to?(:scan_type) && plan.scan_type == :index
        return :sequential_scan if plan.respond_to?(:scan_type) && plan.scan_type == :sequential

        plan.type
      end

      def initialize(logical_plan, operator:, estimated_cost:, estimated_rows:, properties:)
        @logical_plan = logical_plan
        @operator = operator.to_sym
        @estimated_cost = estimated_cost
        @estimated_rows = estimated_rows
        @properties = properties.freeze
        freeze
      end

      def to_h
        {
          operator: @operator,
          estimated_cost: @estimated_cost,
          estimated_rows: @estimated_rows,
          properties: @properties
        }
      end
    end
  end
end
