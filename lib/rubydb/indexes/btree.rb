# frozen_string_literal: true

module RubyDB
  module Indexes
    # B-Tree index implementation
    class BTree < Index
      attr_reader :root, :order, :height

      def initialize(name, table_name, columns, options = {})
        super(name, table_name, columns, options)
        @order = options[:order] || 4
        @height = 0
        @root = nil
        @node_pages = {}
        @next_page = 1000
        @lock = Mutex.new
        
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
          if result.is_a?(Array) && result.size == 2
            left, right, split_key = result
            
            # Create new root
            new_root = BTreeNode.new(allocate_page, false, @order)
            new_root.keys = [split_key]
            new_root.children = [left, right]
            left.parent = new_root
            right.parent = new_root
            
            @root = new_root
            @height += 1
          end
          
          @entries_count += 1
          @modified_at = Time.now
          true
        end
      end

      def delete(key, row_id)
        @lock.synchronize do
          return false if @root.nil?
          
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
          
          @entries_count -= 1 if result
          @modified_at = Time.now
          result
        end
      end

      def search(key)
        @lock.synchronize do
          return nil if @root.nil?
          @root.search(key)
        end
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

      private

      def initialize_root
        @root = BTreeNode.new(allocate_page, true, @order)
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
          row[@columns.first]
        else
          @columns.map { |col| row[col] }
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
            child_min = i == 0 ? min_key : node.keys[i - 1]
            child_max = i == node.children.size - 1 ? max_key : node.keys[i]
            check_node(child, child_min, child_max)
          end
        end
      end
    end
  end
end