# frozen_string_literal: true

module RubyDB
  module Client
    # PreparedStatement - Prepared SQL statement
    class PreparedStatement
      attr_reader :id, :sql, :client, :params

      def initialize(id, sql, client)
        @id = id
        @sql = sql
        @client = client
        @params = []
        @param_count = sql.scan(/\$/).size
        @created_at = Time.now
        @closed = false
        @lock = Mutex.new
      end

      def execute(params = [])
        @lock.synchronize do
          raise ClientError, "Statement is closed" if @closed
          @params = params
          @client.execute(@id, params)
        end
      end

      def execute_batch(params_list)
        @lock.synchronize do
          raise ClientError, "Statement is closed" if @closed
          results = []
          params_list.each do |params|
            results << @client.execute(@id, params)
          end
          results
        end
      end

      def close
        @lock.synchronize do
          return if @closed
          @client.close_statement(@id)
          @closed = true
        end
      end

      def closed?
        @closed
      end

      def to_s
        "#<PreparedStatement id=#{@id} sql=\"#{@sql[0..50]}#{'...' if @sql.length > 50}\">"
      end

      def inspect
        to_s
      end
    end
  end
end