# frozen_string_literal: true

require "set"

module RubyDB
  module Indexes
    # IndexScan - Executes index scans for queries with full production features
    class IndexScan
      attr_reader :index, :scan_type, :conditions, :stats

      SCAN_TYPE_EQUAL = :equal
      SCAN_TYPE_RANGE = :range
      SCAN_TYPE_PREFIX = :prefix
      SCAN_TYPE_FULL = :full
      SCAN_TYPE_MULTI_KEY = :multi_key

      def initialize(index, scan_type = SCAN_TYPE_FULL, conditions = {})
        @index = index
        @scan_type = scan_type
        @conditions = conditions
        @cursor = nil
        @results = nil
        @position = 0
        @lock = Mutex.new
        @limit = conditions[:limit]
        @offset = conditions[:offset] || 0
        @stats = {
          rows_scanned: 0,
          keys_checked: 0,
          matches_found: 0,
          scan_time_ms: 0,
          index_pages_accessed: 0
        }
        @executed = false
        @filter = conditions[:filter]
        @order = conditions[:order] || :asc
        @distinct = conditions[:distinct] || false
      end

      def execute
        @lock.synchronize do
          start_time = Time.now
          @results = []

          case @scan_type
          when SCAN_TYPE_EQUAL
            execute_equal_scan
          when SCAN_TYPE_RANGE
            execute_range_scan
          when SCAN_TYPE_PREFIX
            execute_prefix_scan
          when SCAN_TYPE_MULTI_KEY
            execute_multi_key_scan
          else
            execute_full_scan
          end

          # Apply limit and offset
          if @limit
            @results = @results[@offset, @limit]
          elsif @offset > 0
            @results = @results[@offset..-1] || []
          end

          # Apply distinct if needed
          if @distinct
            @results = distinct_results(@results)
          end

          @executed = true
          @stats[:scan_time_ms] = ((Time.now - start_time) * 1000).round(2)
          @stats[:matches_found] = @results.size
          @results
        end
      end

      def next
        @lock.synchronize do
          return nil if @results.nil?
          return nil if @position >= @results.size

          result = @results[@position]
          @position += 1
          result
        end
      end

      def next_batch(batch_size = 100)
        @lock.synchronize do
          return [] if @results.nil? || @position >= @results.size

          batch = @results[@position, batch_size] || []
          @position += batch.size
          batch
        end
      end

      def reset
        @lock.synchronize do
          @position = 0
          @results = nil
          @executed = false
          @cursor = nil if @cursor
        end
      end

      def row_ids
        @lock.synchronize do
          @results ? @results.map { |r| r[:row_id] } : []
        end
      end

      def keys
        @lock.synchronize do
          @results ? @results.map { |r| r[:key] } : []
        end
      end

      def count
        @results ? @results.size : 0
      end

      def estimate_cost
        case @scan_type
        when SCAN_TYPE_EQUAL
          1
        when SCAN_TYPE_PREFIX
          @index.entries_count / 10
        when SCAN_TYPE_RANGE
          @index.entries_count / 2
        when SCAN_TYPE_MULTI_KEY
          @index.entries_count * 0.75
        else
          @index.entries_count
        end
      end

      def estimate_rows
        case @scan_type
        when SCAN_TYPE_EQUAL
          1
        when SCAN_TYPE_PREFIX
          @index.entries_count / 20
        when SCAN_TYPE_RANGE
          @index.entries_count / 3
        else
          @index.entries_count
        end
      end

      def index_used?
        @executed && @results && @results.any?
      end

      def scan_stats
        @stats.merge({
          scan_type: @scan_type,
          index_type: @index.type,
          index_name: @index.name,
          table_name: @index.table_name,
          columns: @index.columns,
          entries_count: @index.entries_count,
          limit: @limit,
          offset: @offset
        })
      end

      private

      def execute_equal_scan
        key = @conditions[:key]
        return [] unless key

        @stats[:keys_checked] += 1

        if @index.type == :btree || @index.type == :hash
          row_ids = @index.search(key)
          @stats[:rows_scanned] = row_ids.size
          @stats[:index_pages_accessed] = 1

          @results = row_ids.map do |row_id|
            { row_id: row_id, key: key }
          end
        else
          @results = []
        end

        # Apply filter if present
        apply_filter if @filter

        @results
      end

      def execute_range_scan
        start_key = @conditions[:start_key]
        end_key = @conditions[:end_key]
        inclusive_start = @conditions[:inclusive_start] != false
        inclusive_end = @conditions[:inclusive_end] != false

        if @index.type == :btree
          results = @index.range_search(start_key, end_key)
          @stats[:rows_scanned] = results.size
          @stats[:index_pages_accessed] = (results.size / 10.0).ceil + 1

          @results = results.map do |r|
            { row_id: r[:value], key: r[:key] }
          end

          # Filter by inclusivity
          if !inclusive_start && start_key
            @results.reject! { |r| r[:key] == start_key }
          end
          if !inclusive_end && end_key
            @results.reject! { |r| r[:key] == end_key }
          end
        else
          # For non-BTree indexes, fall back to full scan with filtering
          execute_full_scan_with_range_filter(start_key, end_key, inclusive_start, inclusive_end)
        end

        apply_filter if @filter
        @results
      end

      def execute_prefix_scan
        prefix = @conditions[:prefix]
        return [] unless prefix

        if @index.type == :btree
          # For prefix scan, find keys starting with prefix
          start_key = prefix
          end_key = prefix + "\xFF\xFF\xFF"  # Max possible suffix

          results = @index.range_search(start_key, end_key)
          @stats[:rows_scanned] = results.size
          @stats[:index_pages_accessed] = (results.size / 20.0).ceil + 1

          @results = results.map do |r|
            { row_id: r[:value], key: r[:key] }
          end
        else
          # For hash indexes, full scan with prefix filter
          execute_full_scan_with_prefix_filter(prefix)
        end

        apply_filter if @filter
        @results
      end

      def execute_multi_key_scan
        keys = @conditions[:keys]
        return [] unless keys.is_a?(Array) && keys.any?

        @stats[:keys_checked] = keys.size

        all_row_ids = []
        keys.each do |key|
          if @index.type == :btree || @index.type == :hash
            row_ids = @index.search(key)
            all_row_ids.concat(row_ids.map { |rid| { row_id: rid, key: key } })
          end
        end

        # Remove duplicates if needed
        if @conditions[:distinct_keys] != false
          seen = Set.new
          all_row_ids = all_row_ids.select do |entry|
            key = entry[:key]
            if seen.include?(key)
              false
            else
              seen.add(key)
              true
            end
          end
        end

        @stats[:rows_scanned] = all_row_ids.size
        @stats[:index_pages_accessed] = all_row_ids.size
        @results = all_row_ids

        apply_filter if @filter
        @results
      end

      def execute_full_scan
        @results = []

        if @index.type == :btree
          # Use cursor for B-Tree
          @cursor = BTreeCursor.new(@index)
          @cursor.first

          page_count = 0
          while (entry = @cursor.next)
            @stats[:rows_scanned] += 1
            @stats[:keys_checked] += 1
            page_count += 1 if page_count % 50 == 0

            # Apply filter early if possible
            if @filter
              next unless apply_filter_to_entry(entry)
            end

            @results << { row_id: entry[:value], key: entry[:key] }
            break if @limit && @results.size >= @limit + @offset
          end
          @stats[:index_pages_accessed] = (page_count / 50.0).ceil + 1
        else
          # For hash indexes, scan all buckets
          @results = scan_hash_index_full
          @stats[:rows_scanned] = @results.size
          @stats[:index_pages_accessed] = 1
        end

        apply_filter if @filter && !@results.empty?
        @results
      end

      def execute_full_scan_with_range_filter(start_key, end_key, inclusive_start, inclusive_end)
        @results = []

        if @index.type == :btree
          @cursor = BTreeCursor.new(@index)
          @cursor.seek(start_key) if start_key
          @cursor.first unless start_key

          while (entry = @cursor.next)
            break if end_key && entry[:key] > end_key

            @stats[:rows_scanned] += 1
            @stats[:keys_checked] += 1

            # Check inclusivity
            if start_key && entry[:key] == start_key && !inclusive_start
              next
            end
            if end_key && entry[:key] == end_key && !inclusive_end
              next
            end

            if @filter
              next unless apply_filter_to_entry(entry)
            end

            @results << { row_id: entry[:value], key: entry[:key] }
            break if @limit && @results.size >= @limit + @offset
          end
          @stats[:index_pages_accessed] = (results.size / 20.0).ceil + 1
        else
          # Hash index - scan all and filter
          scan_hash_index_full.each do |entry|
            next if start_key && entry[:key] < start_key
            next if end_key && entry[:key] > end_key

            if start_key && entry[:key] == start_key && !inclusive_start
              next
            end
            if end_key && entry[:key] == end_key && !inclusive_end
              next
            end

            @results << entry
          end
        end

        @results
      end

      def execute_full_scan_with_prefix_filter(prefix)
        @results = []

        if @index.type == :btree
          @cursor = BTreeCursor.new(@index)
          @cursor.first

          while (entry = @cursor.next)
            key_str = entry[:key].to_s
            next unless key_str.start_with?(prefix.to_s)

            @stats[:rows_scanned] += 1
            @stats[:keys_checked] += 1

            if @filter
              next unless apply_filter_to_entry(entry)
            end

            @results << { row_id: entry[:value], key: entry[:key] }
            break if @limit && @results.size >= @limit + @offset
          end
        else
          scan_hash_index_full.each do |entry|
            key_str = entry[:key].to_s
            next unless key_str.start_with?(prefix.to_s)
            @results << entry
          end
        end

        @results
      end

      def scan_hash_index_full
        # Access the internal hash table of the hash index
        # This is a production implementation that iterates through all buckets
        results = []
        hash_table = @index.instance_variable_get(:@hash_table)

        if hash_table
          hash_table.each do |_bucket_key, bucket|
            bucket.each do |entry|
              @stats[:rows_scanned] += 1
              @stats[:keys_checked] += 1

              if @filter
                next unless apply_filter_to_entry(entry)
              end

              results << { row_id: entry[:row_id], key: entry[:key] }
              break if @limit && results.size >= @limit + @offset
            end
            break if @limit && results.size >= @limit + @offset
          end
        end

        results
      end

      def apply_filter
        return unless @filter && @results.any?

        @results.select! do |result|
          apply_filter_to_entry(result)
        end
      end

      def apply_filter_to_entry(entry)
        return true unless @filter

        key = entry[:key] || entry[:row_id]
        value = entry[:row_id] || entry[:value]

        @filter.call(key, value)
      end

      def distinct_results(results)
        seen = Set.new
        results.select do |result|
          key = result[:key]
          if seen.include?(key)
            false
          else
            seen.add(key)
            true
          end
        end
      end

      def find_internal_hash_table
        # Try to get hash table from index
        if @index.respond_to?(:hash_table)
          @index.hash_table
        elsif @index.instance_variable_defined?(:@hash_table)
          @index.instance_variable_get(:@hash_table)
        else
          {}
        end
      end
    end
  end
end