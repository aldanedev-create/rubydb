# frozen_string_literal: true

module RubyDB
  module Client
    # Result - Query result set
    class Result
      attr_reader :columns, :rows, :row_count, :affected_rows, :sql
      attr_reader :command_tag, :statement_id, :transaction_id

      def initialize(data = {})
        @columns = data[:columns] || []
        @rows = data[:rows] || []
        @row_count = data[:row_count] || @rows.size
        @affected_rows = data[:affected_rows] || 0
        @sql = data[:sql]
        @command_tag = data[:command_tag] || "SELECT"
        @statement_id = data[:statement_id]
        @transaction_id = data[:transaction_id]
        @success = data[:success] != false
        @error = data[:error]
        @warnings = data[:warnings] || []
        @notice = data[:notice]
        @execution_time_ms = data[:execution_time_ms] || 0
        @created_at = Time.now
        @position = 0
      end

      def success?
        @success
      end

      def error?
        !@success && !@error.nil?
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

      def each
        @rows.each { |row| yield row }
      end

      def each_with_index
        @rows.each_with_index { |row, idx| yield row, idx }
      end

      def each_row
        @rows.each { |row| yield row }
      end

      def each_column
        @columns.each { |col| yield col }
      end

      def column_names
        @columns.map { |c| c[:name] || c }
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
          success: @success,
          error: @error,
          execution_time_ms: @execution_time_ms
        }
      end

      def to_json
        JSON.generate(to_hash)
      end

      def inspect
        rows_preview = @rows.first(3).map(&:inspect).join(", ")
        more = @rows.size > 3 ? "..." : ""
        "#<Result rows=#{@row_count} columns=#{@columns.size} data=[#{rows_preview}#{more}]>"
      end

      def to_s
        if @rows.empty?
          "Result: #{@command_tag} (0 rows)"
        else
          "Result: #{@command_tag} (#{@row_count} rows)"
        end
      end

      # Enumerable support
      include Enumerable

      def size
        @row_count
      end

      alias length size
      alias count size
    end
  end
end