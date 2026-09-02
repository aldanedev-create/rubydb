# frozen_string_literal: true

module RubyDB
  module Recovery
    # Redo - Handles REDO operations during recovery
    class Redo
      attr_reader :stats

      def initialize(engine, wal, config = {})
        @engine = engine
        @wal = wal
        @config = config
        @stats = {
          redo_count: 0,
          redo_failures: 0,
          total_redo_time_ms: 0,
          avg_redo_time_ms: 0,
          last_redo_lsn: nil,
          last_redo_time: nil
        }
        @lock = Mutex.new
        @batch_size = config[:batch_size] || 1000
      end

      def redo_records(records, from_lsn = nil)
        @lock.synchronize do
          start_time = Time.now

          # Filter records to redo
          redo_records = records
          if from_lsn
            redo_records = redo_records.select { |r| r.lsn && r.lsn >= from_lsn }
          end

          # Group by transaction
          grouped = group_by_transaction(redo_records)

          # Process each transaction
          count = 0
          grouped.each do |transaction_id, transaction_records|
            begin
              count += redo_transaction(transaction_records)
            rescue => e
              @stats[:redo_failures] += 1
              raise if @config[:stop_on_error]
            end
          end

          elapsed_ms = (Time.now - start_time) * 1000
          @stats[:redo_count] += count
          @stats[:total_redo_time_ms] += elapsed_ms
          @stats[:avg_redo_time_ms] = @stats[:total_redo_time_ms] / @stats[:redo_count] if @stats[:redo_count] > 0

          if redo_records.any?
            @stats[:last_redo_lsn] = redo_records.last.lsn
            @stats[:last_redo_time] = Time.now
          end

          count
        end
      end

      def redo_transaction(records)
        count = 0

        records.each do |record|
          # Skip if already applied
          next if already_applied?(record)

          case record.type
          when :insert
            redo_insert(record)
            count += 1
          when :update
            redo_update(record)
            count += 1
          when :delete
            redo_delete(record)
            count += 1
          when :create_table
            redo_create_table(record)
            count += 1
          when :drop_table
            redo_drop_table(record)
            count += 1
          when :schema_change
            redo_schema_change(record)
            count += 1
          end
        end

        count
      end

      def redo_insert(record)
        data = record.data
        return unless data

        # Re-insert the row
        table = data[:table]
        columns = data[:columns] || []
        values = data[:values] || {}

        # Check if row already exists
        existing = @engine.select_row(table, data[:row_id], columns) if data[:row_id]
        if existing
          # Update instead of insert
          @engine.update_row(table, data[:row_id], values)
        else
          @engine.insert_row(table, columns, values)
        end
      end

      def redo_update(record)
        data = record.data
        return unless data

        # Re-apply the update
        table = data[:table]
        row_id = data[:row_id]
        values = data[:values] || {}

        @engine.update_row(table, row_id, values)
      end

      def redo_delete(record)
        data = record.data
        return unless data

        # Re-delete the row
        table = data[:table]
        row_id = data[:row_id]

        @engine.delete_row(table, row_id)
      end

      def redo_create_table(record)
        data = record.data
        return unless data

        # Re-create the table
        table_name = data[:table_name]
        columns = data[:columns] || []

        unless @engine.table_exists?(table_name)
          @engine.create_table(table_name, columns)
        end
      end

      def redo_drop_table(record)
        data = record.data
        return unless data

        # Re-drop the table
        table_name = data[:table_name]

        if @engine.table_exists?(table_name)
          @engine.drop_table(table_name)
        end
      end

      def redo_schema_change(record)
        data = record.data
        return unless data

        case data[:operation]
        when :add_column
          table = @engine.find_table(data[:table_name])
          table.add_column(data[:column_name], data[:column_type]) if table
        when :drop_column
          table = @engine.find_table(data[:table_name])
          table.drop_column(data[:column_name]) if table
        when :rename_table
          @engine.rename_table(data[:old_name], data[:new_name])
        end
      end

      def already_applied?(record)
        data = record.data || {}
        case record.type
        when :insert
          return false unless data[:row_id]
          !@engine.select_row(data[:table], data[:row_id], data[:columns] || []).nil?
        when :update
          row = data[:row_id] && @engine.select_row(data[:table], data[:row_id], data[:columns] || [])
          row && data.fetch(:values, {}).all? { |key, value| row[key] == value || row[key.to_s] == value }
        when :delete
          data[:row_id] && @engine.select_row(data[:table], data[:row_id], data[:columns] || []).nil?
        when :create_table
          @engine.table_exists?(data[:table_name])
        when :drop_table
          !@engine.table_exists?(data[:table_name])
        when :schema_change
          schema_change_applied?(data)
        else
          false
        end
      rescue StandardError
        false
      end

      def schema_change_applied?(data)
        case data[:operation]
        when :add_column
          table = @engine.find_table(data[:table_name])
          table && table.columns.any? { |column| column.name.to_s == data[:column_name].to_s }
        when :drop_column
          table = @engine.find_table(data[:table_name])
          table && !table.columns.any? { |column| column.name.to_s == data[:column_name].to_s }
        when :rename_table
          @engine.table_exists?(data[:new_name]) && !@engine.table_exists?(data[:old_name])
        else
          false
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
            last_redo_lsn: @stats[:last_redo_lsn]&.to_s
          })
        end
      end
    end
  end
end
