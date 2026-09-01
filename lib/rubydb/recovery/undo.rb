# frozen_string_literal: true

module RubyDB
  module Recovery
    # Undo - Handles UNDO operations during recovery
    class Undo
      attr_reader :stats

      def initialize(engine, wal, config = {})
        @engine = engine
        @wal = wal
        @config = config
        @stats = {
          undo_count: 0,
          undo_failures: 0,
          total_undo_time_ms: 0,
          avg_undo_time_ms: 0,
          last_undo_lsn: nil,
          last_undo_time: nil
        }
        @lock = Mutex.new
        @batch_size = config[:batch_size] || 1000
      end

      def undo_records(records)
        @lock.synchronize do
          start_time = Time.now

          # Group by transaction (undo in reverse order within transaction)
          grouped = group_by_transaction(records)

          # Process each transaction in reverse (LIFO)
          count = 0
          grouped.each do |transaction_id, transaction_records|
            begin
              # Undo in reverse order within transaction
              count += undo_transaction(transaction_records.reverse)
            rescue => e
              @stats[:undo_failures] += 1
              raise if @config[:stop_on_error]
            end
          end

          elapsed_ms = (Time.now - start_time) * 1000
          @stats[:undo_count] += count
          @stats[:total_undo_time_ms] += elapsed_ms
          @stats[:avg_undo_time_ms] = @stats[:total_undo_time_ms] / @stats[:undo_count] if @stats[:undo_count] > 0

          if records.any?
            @stats[:last_undo_lsn] = records.last.lsn
            @stats[:last_undo_time] = Time.now
          end

          count
        end
      end

      def undo_transaction(records)
        count = 0

        records.each do |record|
          case record.type
          when :insert
            undo_insert(record)
            count += 1
          when :update
            undo_update(record)
            count += 1
          when :delete
            undo_delete(record)
            count += 1
          when :create_table
            undo_create_table(record)
            count += 1
          when :drop_table
            undo_drop_table(record)
            count += 1
          when :schema_change
            undo_schema_change(record)
            count += 1
          end
        end

        count
      end

      def undo_insert(record)
        data = record.data
        return unless data

        # Undo insert: delete the row
        table = data[:table]
        row_id = data[:row_id]

        if row_id
          # Get the row to verify it exists
          columns = @engine.table_columns(table)
          row = @engine.select_row(table, row_id, columns)
          if row
            @engine.delete_row(table, row_id)
          end
        end
      end

      def undo_update(record)
        data = record.data
        return unless data

        # Undo update: restore old values
        table = data[:table]
        row_id = data[:row_id]
        old_values = data[:old_values]

        if row_id && old_values
          # Verify the row still exists with the expected values
          columns = @engine.table_columns(table)
          current_row = @engine.select_row(table, row_id, columns)
          if current_row
            @engine.update_row(table, row_id, old_values)
          end
        end
      end

      def undo_delete(record)
        data = record.data
        return unless data

        # Undo delete: reinsert the row
        table = data[:table]
        columns = data[:columns] || []
        row_data = data[:row_data] || {}

        if table && row_data.any?
          # Check if row still exists
          existing = @engine.select_row(table, data[:row_id], columns) if data[:row_id]
          unless existing
            @engine.insert_row(table, columns, row_data)
          end
        end
      end

      def undo_create_table(record)
        data = record.data
        return unless data

        # Undo create table: drop the table
        table_name = data[:table_name]

        if @engine.table_exists?(table_name)
          @engine.drop_table(table_name)
        end
      end

      def undo_drop_table(record)
        data = record.data
        return unless data

        # Undo drop table: re-create the table
        table_name = data[:table_name]
        columns = data[:columns] || []

        unless @engine.table_exists?(table_name)
          @engine.create_table(table_name, columns)
        end
      end

      def undo_schema_change(record)
        data = record.data
        return unless data

        case data[:operation]
        when :add_column
          # Undo add column: drop the column
          table = @engine.find_table(data[:table_name])
          table.drop_column(data[:column_name]) if table
        when :drop_column
          # Undo drop column: add the column back
          table = @engine.find_table(data[:table_name])
          table.add_column(data[:column_name], data[:column_type]) if table
        when :rename_table
          # Undo rename table: rename back
          @engine.rename_table(data[:new_name], data[:old_name])
        end
      end

      def group_by_transaction(records)
        groups = {}
        records.each do |record|
          tx_id = record.transaction_id
          groups[tx_id] ||= []
          groups[tx_id] << record
        end
        groups
      end

      def stats
        @lock.synchronize do
          @stats.merge({
            batch_size: @batch_size,
            last_undo_lsn: @stats[:last_undo_lsn]&.to_s
          })
        end
      end
    end
  end
end