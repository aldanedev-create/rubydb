# frozen_string_literal: true

module RubyDB
  module Client
    # Statement - SQL statement
    class Statement
      attr_reader :sql, :params, :client, :result

      def initialize(sql, client)
        @sql = sql
        @client = client
        @result = nil
        @executed = false
        @params = []
        @param_count = sql.scan(/\$/).size
        @created_at = Time.now
        @lock = Mutex.new
      end

      def execute(params = [])
        @lock.synchronize do
          @params = params
          @result = @client.query(@sql, params)
          @executed = true
          @result
        end
      end

      def execute_batch(params_list)
        @lock.synchronize do
          results = []
          params_list.each do |params|
            results << execute(params)
          end
          results
        end
      end

      def executed?
        @executed
      end

      def to_s
        @sql
      end

      def inspect
        "#<Statement sql=\"#{@sql[0..50]}#{'...' if @sql.length > 50}\">"
      end
    end
  end
end