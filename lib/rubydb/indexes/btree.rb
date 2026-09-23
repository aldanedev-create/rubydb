# frozen_string_literal: true

require "monitor"

module RubyDB
  module Indexes
    # B-Tree index implementation
    class BTree < Index
      attr_reader :root, :order, :height

      def initialize(name, table_name, columns, options = {})
        super
        @order = options[:order] || 4
        @height = 0
        @root = nil
        @node_pages = {}
        @exact_rows = Hash.new { |hash, key| hash[key] = [] }
        @next_page = 1000
        @lock = Monitor.new

        # Initialize root node
        initialize_root
      end

      def insert(key, row_id)
        @lock.synchronize do
          if @root.nil?
            initialize_root
          end

          result = @root.insert(key, row_id)

          # Handle root split
          if result.is_a?(Array) && result.size == 3
            left, right, split_key = result

            # Create new root
            new_root = BTreeNode.new(allocate_page, false, @order, method(:allocate_page))
            new_root.keys = [split_key]
            new_root.children = [left, right]
            left.parent = new_root
            right.parent = new_root

            @root = new_root
            @height += 1
          end

          @entries_count += 1
          @exact_rows[normalize_exact_key(key)] << row_id
          @modified_at = Time.now
          true
        end
      end

      def delete(key, row_id)
        @lock.synchronize do
          return false if @root.nil?
          exact_key = normalize_exact_key(key)
          matching_ids = @exact_rows.fetch(exact_key, nil)
          return false unless matching_ids&.include?(row_id)

          # The node-level delete takes a key, not a row ID. Rebuild only
          # when duplicate keys exist, so a nonunique index never removes a
          # different row's entry from ordered/range scans.
          if matching_ids.size > 1
            entries = snapshot_entries
            removed = false
            entries.reject! do |entry|
              match = !removed && entry[:value] == row_id && normalize_exact_key(entry[:key]) == exact_key
              removed = true if match
              match
            end
            clear
            entries.each { |entry| insert(entry[:key], entry[:value]) }
            return true
          end

          result = @root.delete(key)

          # Handle root underflow
          if result == :underflow && @root.keys.empty?
            if @root.is_leaf
              @root = nil
              @height = 0
            else
              @root = @root.children.first
              @root.parent = nil
              @height -= 1
            end
          end

          if result
            @exact_rows.fetch(exact_key, nil)&.delete(row_id)
            @exact_rows.delete(exact_key) if @exact_rows.fetch(exact_key, nil)&.empty?
            @entries_count -= 1
          end
          @modified_at = Time.now
          result
        end
      end

      def search(key)
        @lock.synchronize do
          @exact_rows.fetch(normalize_exact_key(key), nil)&.first
        end
      end

      def search_all(key)
        @lock.synchronize { @exact_rows.fetch(normalize_exact_key(key), []).dup }
      end

      def range_search(start_key, end_key)
        @lock.synchronize do
          return [] if @root.nil?
          @root.range_search(start_key, end_key)
        end
      end

      def build(rows)
        @lock.synchronize do
          clear

          rows.each do |row|
            key = extract_key(row)
            row_id = row[:_row_id] || row["id"] || row[:id]
            insert(key, row_id)
          end

          @is_built = true
          @modified_at = Time.now
          true
        end
      end

      def clear
        @lock.synchronize do
          @root = nil
          @node_pages.clear
          @height = 0
          @entries_count = 0
          @exact_rows.clear
          initialize_root
          true
        end
      end

      def validate
        return true if @root.nil?

        # Check B-Tree properties
        check_node(@root, nil, nil)
        true
      end

      def analyze
        super.merge({
          order: @order,
          height: @height,
          nodes: @node_pages.size,
          root_page: @root&.page_number,
          is_built: @is_built
        })
      end

      # Return a stable, ordered copy of the in-memory B-tree entries. Indexes
      # are rebuilt from metadata on open, so this immutable value is the
      # correct hand-off to a storage snapshot; it is not a second persisted
      # index format.
      def snapshot_entries
        @lock.synchronize do
          return [] unless @root

          leaf = @root
          leaf = leaf.children.first until leaf.is_leaf
          entries = []
          while leaf
            leaf.keys.each_with_index do |key, index|
              entries << {key: key, value: leaf.values[index]}
            end
            leaf = leaf.next_leaf
          end
          entries
        end
      end

      private

      def initialize_root
        @root = BTreeNode.new(allocate_page, true, @order, method(:allocate_page))
        @height = 1
        @is_built = false
      end

      def allocate_page
        page = @next_page
        @next_page += 1
        @node_pages[page] = true
        page
      end

      def extract_key(row)
        if @columns.size == 1
          column = @columns.first
          return row[column] if row.key?(column)
          return row[column.to_s] if row.key?(column.to_s)

          row[column.to_sym] if column.respond_to?(:to_sym)
        else
          @columns.map do |column|
            next row[column] if row.key?(column)
            next row[column.to_s] if row.key?(column.to_s)

            column.respond_to?(:to_sym) ? row[column.to_sym] : nil
          end
        end
      end

      def check_node(node, min_key, max_key)
        # Check keys are in order
        (0...node.keys.size - 1).each do |i|
          raise "B-Tree invariant violated: keys out of order" if node.keys[i] > node.keys[i + 1]
        end

        # Check min/max constraints
        if min_key && node.keys.first < min_key
          raise "B-Tree invariant violated: key < min"
        end

        if max_key && node.keys.last > max_key
          raise "B-Tree invariant violated: key > max"
        end

        # Check children
        unless node.is_leaf
          node.children.each_with_index do |child, i|
            child_min = (i == 0) ? min_key : node.keys[i - 1]
            child_max = (i == node.children.size - 1) ? max_key : node.keys[i]
            check_node(child, child_min, child_max)
          end
        end
      end
    end
  end
end
