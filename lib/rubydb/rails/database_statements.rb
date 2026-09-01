# frozen_string_literal: true

module RubyDB
  module Rails
    # DatabaseStatements - Database statement methods for Rails
    module DatabaseStatements
      def execute(sql, name = nil)
        log(sql, name) do
          @connection.execute(sql)
        end
      end

      def exec_query(sql, name = nil, binds = [])
        log(sql, name) do
          # Process binds
          params = binds.map { |bind| bind.value }
          @connection.execute(sql, params)
        end
      end

      def exec_delete(sql, name = nil, binds = [])
        log(sql, name) do
          params = binds.map { |bind| bind.value }
          result = @connection.execute(sql, params)
          result.affected_rows
        end
      end

      def exec_update(sql, name = nil, binds = [])
        log(sql, name) do
          params = binds.map { |bind| bind.value }
          result = @connection.execute(sql, params)
          result.affected_rows
        end
      end

      def exec_insert(sql, name = nil, binds = [], pk = nil, sequence_name = nil)
        log(sql, name) do
          params = binds.map { |bind| bind.value }
          result = @connection.execute(sql, params)
          {
            row_count: result.affected_rows,
            last_insert_id: result.first && result.first["id"]
          }
        end
      end

      def exec_query_with_result(sql, name = nil, binds = [])
        exec_query(sql, name, binds)
      end

      def insert(sql, name = nil, pk = nil, id_value = nil, sequence_name = nil, binds = [])
        result = exec_insert(sql, name, binds, pk, sequence_name)
        id_value || result[:last_insert_id]
      end

      def update(sql, name = nil, binds = [])
        exec_update(sql, name, binds)
      end

      def delete(sql, name = nil, binds = [])
        exec_delete(sql, name, binds)
      end

      def select_all(sql, name = nil, binds = [])
        exec_query(sql, name, binds)
      end

      def select_one(sql, name = nil, binds = [])
        result = exec_query(sql, name, binds)
        result.first
      end

      def select_value(sql, name = nil, binds = [])
        result = exec_query(sql, name, binds)
        result.first&.values&.first
      end

      def select_values(sql, name = nil, binds = [])
        result = exec_query(sql, name, binds)
        result.map { |row| row.values.first }
      end

      def select_rows(sql, name = nil, binds = [])
        result = exec_query(sql, name, binds)
        result.map { |row| row.values }
      end

      def begin_db_transaction
        @connection.begin_db_transaction
      end

      def commit_db_transaction
        @connection.commit_db_transaction
      end

      def rollback_db_transaction
        @connection.rollback_db_transaction
      end

      def in_transaction?
        @connection.in_transaction?
      end

      def transaction_joinable?
        true
      end

      def transactional?
        true
      end

      def supports_transactions?
        true
      end

      def transaction_state
        @connection.transaction_state
      end
    end
  end
end