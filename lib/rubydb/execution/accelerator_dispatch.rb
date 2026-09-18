# frozen_string_literal: true

module RubyDB
  module Execution
    # Keeps capability checks and result validation outside the executor's SQL
    # logic. The Go path is an optimization; this object never makes it the
    # source of truth.
    class AcceleratorDispatch
      def initialize(accelerator)
        @accelerator = accelerator
      end

      def preferred?(workload)
        @accelerator&.manager&.acceleration_preferred?(workload)
      end

      def equivalent?(left, right)
        normalize(left) == normalize(right)
      end

      private

      def normalize(rows)
        rows.map do |row|
          row.each_with_object({}) { |(key, value), normalized| normalized[key.to_s] = value }
        end
      end
    end
  end
end
