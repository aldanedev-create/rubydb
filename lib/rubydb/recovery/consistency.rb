# frozen_string_literal: true

require "digest"

module RubyDB
  module Recovery
    # CorruptionDetector - Detects database corruption
    class CorruptionDetector
      attr_reader :stats

      def initialize(engine, config = {})
        @engine = engine
        @config = config
        @checksums = {}
        @checksum_cache = {}
        @stats = {
          detections: 0,
          false_positives: 0,
          total_checks: 0,
          corrupted_pages: 0,
          corrupted_records: 0,
          corrupted_indexes: 0,
          last_detection_time: nil,
          last_detection_result: nil
        }
        @lock = Mutex.new
        @page_checksums = {}
      end

      def detect_corruption(scan_all = false)
        @lock.synchronize do
          @stats[:total_checks] += 1
          results = {
            corrupted: false,
            issues: [],
            pages: [],
            records: [],
            indexes: [],
            recommendations: []
          }

          # Check page corruption
          page_results = check_pages(scan_all)
          results[:pages] = page_results[:corrupted]
          results[:issues].concat(page_results[:issues])
          results[:corrupted] = true if page_results[:corrupted].any?

          # Check record corruption
          record_results = check_records(scan_all)
          results[:records] = record_results[:corrupted]
          results[:issues].concat(record_results[:issues])
          results[:corrupted] = true if record_results[:corrupted].any?

          # Check index corruption
          index_results = check_indexes(scan_all)
          results[:indexes] = index_results[:corrupted]
          results[:issues].concat(index_results[:issues])
          results[:corrupted] = true if index_results[:corrupted].any?

          # Generate recommendations
          results[:recommendations] = generate_recommendations(results)

          # Update stats
          if results[:corrupted]
            @stats[:detections] += 1
            @stats[:corrupted_pages] = results[:pages].size
            @stats[:corrupted_records] = results[:records].size
            @stats[:corrupted_indexes] = results[:indexes].size
            @stats[:last_detection_time] = Time.now
            @stats[:last_detection_result] = results
          end

          results
        end
      end

      def check_page(page_number)
        @lock.synchronize do
          result = { corrupted: false, issues: [] }

          begin
            page = @engine.read_page(page_number)
            return result unless page

            # Check page header
            header = page.header
            if header.nil?
              result[:corrupted] = true
              result[:issues] << { type: "page_header", page: page_number, message: "Missing header" }
              return result
            end

            # Check page size
            if header.page_size != page.size
              result[:corrupted] = true
              result[:issues] << { type: "page_size", page: page_number, message: "Invalid page size" }
            end

            # Check page checksum
            if checksum_mismatch?(page)
              result[:corrupted] = true
              result[:issues] << { type: "checksum", page: page_number, message: "Checksum mismatch" }
            end

            # Check page data
            if page.data.nil? || page.data.bytesize != page.size
              result[:corrupted] = true
              result[:issues] << { type: "page_data", page: page_number, message: "Invalid page data" }
            end

          rescue => e
            result[:corrupted] = true
            result[:issues] << { type: "page_read", page: page_number, message: e.message }
          end

          result
        end
      end

      def check_record(table_name, row_id)
        @lock.synchronize do
          result = { corrupted: false, issues: [] }

          begin
            columns = @engine.table_columns(table_name)
            row = @engine.select_row(table_name, row_id, columns)
            return result unless row

            # Validate each column value
            columns.each do |col|
              value = row[col.name]
              next if value.nil? && col.nullable?

              # Check type validity
              unless valid_value_type?(value, col.type_class)
                result[:corrupted] = true
                result[:issues] << {
                  type: "record_value",
                  table: table_name,
                  row: row_id,
                  column: col.name,
                  message: "Invalid value type"
                }
              end
            end

          rescue => e
            result[:corrupted] = true
            result[:issues] << {
              type: "record_read",
              table: table_name,
              row: row_id,
              message: e.message
            }
          end

          result
        end
      end

      def check_index(index_name)
        @lock.synchronize do
          result = { corrupted: false, issues: [] }

          begin
            if @engine.respond_to?(:index_manager)
              index = @engine.index_manager.get_index(index_name)
              return result unless index

              # Validate index
              if index.respond_to?(:validate)
                index.validate
              end

              # Check index entries
              entries = index.entries_count
              if entries < 0
                result[:corrupted] = true
                result[:issues] << {
                  type: "index_entries",
                  index: index_name,
                  message: "Invalid entry count"
                }
              end
            end

          rescue => e
            result[:corrupted] = true
            result[:issues] << {
              type: "index_check",
              index: index_name,
              message: e.message
            }
          end

          result
        end
      end

      def repair_corruption(corruption_info)
        @lock.synchronize do
          results = { repaired: false, actions: [] }

          corruption_info[:issues].each do |issue|
            case issue[:type]
            when "page_header"
              repaired = repair_page_header(issue[:page])
              results[:actions] << { type: "repair_page_header", page: issue[:page], success: repaired }
            when "checksum"
              repaired = repair_checksum(issue[:page])
              results[:actions] << { type: "repair_checksum", page: issue[:page], success: repaired }
            when "record_value"
              repaired = repair_record(issue[:table], issue[:row], issue[:column])
              results[:actions] << {
                type: "repair_record",
                table: issue[:table],
                row: issue[:row],
                column: issue[:column],
                success: repaired
              }
            when "index_entries"
              repaired = repair_index(issue[:index])
              results[:actions] << { type: "repair_index", index: issue[:index], success: repaired }
            end
          end

          results[:repaired] = results[:actions].all? { |a| a[:success] }
          results
        end
      end

      def stats
        @lock.synchronize do
          @stats.merge({
            checksum_cache_size: @checksum_cache.size,
            page_checksums: @page_checksums.size,
            last_detection: @stats[:last_detection_time]&.iso8601
          })
        end
      end

      private

      def check_pages(scan_all)
        result = { corrupted: [], issues: [] }

        begin
          page_manager = @engine.page_manager
          return result unless page_manager

          pages_to_check = scan_all ? (0...page_manager.total_pages) : [page_manager.current_page]

          pages_to_check.each do |page_number|
            page_result = check_page(page_number)
            if page_result[:corrupted]
              result[:corrupted] << page_number
              result[:issues].concat(page_result[:issues])
            end
          end

        rescue => e
          result[:issues] << { type: "page_scan", message: e.message }
        end

        result
      end

      def check_records(scan_all)
        result = { corrupted: [], issues: [] }

        begin
          tables = @engine.list_tables
          return result if tables.empty?

          tables.each do |table_name|
            columns = @engine.table_columns(table_name)
            rows = @engine.select_rows(table_name, columns)

            sample_size = scan_all ? rows.size : [rows.size, 100].min
            rows.first(sample_size).each do |row|
              row_id = row[:_row_id] || row["_row_id"]
              record_result = check_record(table_name, row_id)
              if record_result[:corrupted]
                result[:corrupted] << { table: table_name, row: row_id }
                result[:issues].concat(record_result[:issues])
              end
            end
          end

        rescue => e
          result[:issues] << { type: "record_scan", message: e.message }
        end

        result
      end

      def check_indexes(scan_all)
        result = { corrupted: [], issues: [] }

        begin
          if @engine.respond_to?(:index_manager)
            index_manager = @engine.index_manager
            indexes = index_manager.indexes

            indexes.each do |name, _|
              index_result = check_index(name)
              if index_result[:corrupted]
                result[:corrupted] << name
                result[:issues].concat(index_result[:issues])
              end
            end
          end

        rescue => e
          result[:issues] << { type: "index_scan", message: e.message }
        end

        result
      end

      def checksum_mismatch?(page)
        # Calculate page checksum
        current_checksum = calculate_checksum(page.data)
        stored_checksum = page.header.checksum rescue 0

        current_checksum != stored_checksum
      end

      def calculate_checksum(data)
        Digest::SHA256.hexdigest(data)[0...16]
      end

      def valid_value_type?(value, type)
        return true if value.nil?

        case type
        when :integer, :bigint, :smallint
          value.is_a?(Integer)
        when :float, :decimal
          value.is_a?(Numeric)
        when :boolean
          [true, false].include?(value)
        when :text, :varchar, :char
          value.is_a?(String)
        when :date, :time, :timestamp
          value.is_a?(Time) || value.is_a?(Date) || value.is_a?(DateTime)
        when :blob
          value.is_a?(String)
        when :json
          value.is_a?(Hash) || value.is_a?(Array)
        else
          true
        end
      end

      def repair_page_header(page_number)
        begin
          page = @engine.read_page(page_number)
          return false unless page

          # Rebuild header
          page.header.page_number = page_number
          page.header.page_size = page.size
          page.header.header_size = 64
          page.header.data_end = 64
          page.header.flags = 0
          page.header.checksum = calculate_checksum(page.data)
          page.header.version = 1
          page.header.page_type = 0

          page.write_header
          @engine.write_page(page)
          true
        rescue
          false
        end
      end

      def repair_checksum(page_number)
        begin
          page = @engine.read_page(page_number)
          return false unless page

          page.header.checksum = calculate_checksum(page.data)
          page.write_header
          @engine.write_page(page)
          true
        rescue
          false
        end
      end

      def repair_record(table, row_id, column)
        begin
          columns = @engine.table_columns(table)
          row = @engine.select_row(table, row_id, columns)
          return false unless row

          # Set column to default value
          col_def = columns.find { |c| c.name == column }
          row[column] = col_def.default if col_def && col_def.has_default?

          @engine.update_row(table, row_id, row)
          true
        rescue
          false
        end
      end

      def repair_index(index_name)
        begin
          if @engine.respond_to?(:index_manager)
            @engine.index_manager.rebuild_index(index_name)
            true
          else
            false
          end
        rescue
          false
        end
      end

      def generate_recommendations(results)
        recommendations = []

        if results[:pages].any?
          recommendations << {
            action: "repair_pages",
            pages: results[:pages],
            description: "Repair corrupted pages"
          }
        end

        if results[:records].any?
          recommendations << {
            action: "repair_records",
            records: results[:records],
            description: "Repair corrupted records"
          }
        end

        if results[:indexes].any?
          recommendations << {
            action: "rebuild_indexes",
            indexes: results[:indexes],
            description: "Rebuild corrupted indexes"
          }
        end

        if results[:corrupted]
          recommendations << {
            action: "create_backup",
            description: "Create backup before repairs"
          }
        end

        recommendations
      end
    end
  end
end