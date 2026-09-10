# frozen_string_literal: true

module RubyDB
  module Rails
    # Result - Query result adapter for Rails
    class Result
      include Enumerable

      attr_reader :columns, :rows, :row_count, :affected_rows
      attr_reader :command_tag, :statement_id, :row_id, :inserted_id

      def initialize(result)
        @columns = result[:columns] || result[:column_names] || []
        @rows = result[:rows] || []
        @row_count = result[:row_count] || @rows.size
        @affected_rows = result[:affected_rows] || 0
        @command_tag = result[:command_tag] || "SELECT"
        @statement_id = result[:statement_id]
        @row_id = result[:row_id]
        @inserted_id = result[:inserted_id]
        @transaction_id = result[:transaction_id]
        @success = result[:success] != false
        @error = result[:error]
        @execution_time = result[:execution_time_ms] || 0
        @position = 0
      end

      def success?
        @success
      end

      def error?
        @success == false && !@error.nil?
      end

      def empty?
        @rows.empty?
      end

      def first
        @rows.first
      end

      def last
        @rows.last
      end

      def [](index)
        @rows[index]
      end

      def each(&)
        @rows.each(&)
      end

      def each_with_index(&)
        @rows.each_with_index(&)
      end

      def each_row(&)
        @rows.each(&)
      end

      def each_column(&)
        @columns.each(&)
      end

      def column_names
        @columns.map do |column|
          column.is_a?(Hash) ? (column[:name] || column["name"] || column) : column
        end
      end

      def column_types
        @columns.map { |c| c[:type] || "text" }
      end

      def to_a
        @rows
      end

      def to_hash
        {
          columns: @columns,
          rows: @rows,
          row_count: @row_count,
          affected_rows: @affected_rows,
          command_tag: @command_tag,
          row_id: @row_id,
          inserted_id: @inserted_id,
          success: @success,
          error: @error,
          execution_time_ms: @execution_time
        }
      end

      def to_ary
        @rows
      end

      def size
        @row_count
      end

      alias_method :length, :size
      alias_method :count, :size

      def inspect
        rows_preview = @rows.first(3).map(&:inspect).join(", ")
        more = (@rows.size > 3) ? "..." : ""
        "#<Result rows=#{@row_count} columns=#{@columns.size} data=[#{rows_preview}#{more}]>"
      end

      def to_s
        if @rows.empty?
          "Result: #{@command_tag} (0 rows)"
        else
          "Result: #{@command_tag} (#{@row_count} rows)"
        end
      end
    end
  end
end
