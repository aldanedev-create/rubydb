# frozen_string_literal: true

module RubyDB
  module Indexes
    # B-Tree node implementation
    class BTreeNode
      attr_reader :page_number, :is_leaf, :keys, :values, :children, :parent
      attr_writer :parent
      attr_accessor :next_leaf, :prev_leaf

      def initialize(page_number, is_leaf = true, order = 4, page_allocator = nil)
        @page_number = page_number
        @is_leaf = is_leaf
        @order = order
        @keys = []
        @values = []
        @children = []
        @parent = nil
        @next_leaf = nil
        @prev_leaf = nil
        @min_keys = (order / 2.0).ceil - 1
        @max_keys = order - 1
        @dirty = false
        @page_allocator = page_allocator
      end

      def insert(key, value)
        if @is_leaf
          insert_into_leaf(key, value)
        else
          insert_into_internal(key, value)
        end
      end

      def insert_into_leaf(key, value)
        # Find position to insert
        pos = find_insert_position(key)
        
        # Insert key and value
        @keys.insert(pos, key)
        @values.insert(pos, value)
        @dirty = true
        
        # Check if node needs to split
        if @keys.size > @max_keys
          return split
        end
        
        self
      end

      def insert_into_internal(key, value)
        # Find child to insert into
        pos = find_child_position(key)
        child = @children[pos]
        
        result = child.insert(key, value)
        
        # If child was split, handle the split
        if result.is_a?(Array) && result.size == 3
          left_child, right_child, split_key = result
          
          # Replace child with left child
          @children[pos] = left_child
          left_child.parent = self
          
          # Insert right child and split key
          @keys.insert(pos, split_key)
          @children.insert(pos + 1, right_child)
          right_child.parent = self
          @dirty = true
          
          # Check if this node needs to split
          if @keys.size > @max_keys
            return split
          end
        end
        
        self
      end

      def split
        # Find middle position
        mid = @keys.size / 2
        
        # Create new node
        new_node = BTreeNode.new(allocate_page, @is_leaf, @order, @page_allocator)
        
        # Split keys and values
        if @is_leaf
          # Leaf split - keep all keys in both nodes
          split_key = @keys[mid]
          
          # Move half of keys/values to new node
          new_node.keys = @keys[mid..-1]
          new_node.values = @values[mid..-1]
          
          @keys = @keys[0...mid]
          @values = @values[0...mid]
          
          # Update leaf links
          new_node.next_leaf = @next_leaf
          new_node.prev_leaf = self
          @next_leaf = new_node
          
          # Return left, right, and split key
          [self, new_node, split_key]
        else
          # Internal split - promote middle key
          split_key = @keys[mid]
          
          # Right child gets keys after mid
          new_node.keys = @keys[mid + 1..-1]
          new_node.children = @children[mid + 1..-1]
          
          # Left child keeps keys before mid
          @keys = @keys[0...mid]
          @children = @children[0...mid + 1]
          
          # Update parent references
          new_node.children.each { |c| c.parent = new_node }
          
          [self, new_node, split_key]
        end
      end

      def search(key)
        if @is_leaf
          # Linear search in leaf
          pos = find_position(key)
          return @values[pos] if pos < @keys.size && @keys[pos] == key
          nil
        else
          # Search in child
          pos = find_child_position(key)
          @children[pos].search(key)
        end
      end

      def range_search(start_key, end_key)
        results = []
        
        if @is_leaf
          # Collect keys in range
          start_pos = find_insert_position(start_key)
          end_pos = find_insert_position(end_key + 1) rescue @keys.size - 1
          
          (start_pos..end_pos).each do |pos|
            break if pos >= @keys.size
            break if @keys[pos] > end_key
            results << { key: @keys[pos], value: @values[pos] }
          end
        else
          # Find the starting leaf and walk the linked leaf chain so ranges
          # spanning multiple pages return every matching entry.
          pos = find_child_position(start_key)
          leaf = @children[pos]
          until leaf.is_leaf
            leaf = leaf.children[leaf.find_child_position(start_key)]
          end
          while leaf
            leaf.keys.each_with_index do |key, index|
              next if key < start_key
              return results if key > end_key
              results << { key: key, value: leaf.values[index] }
            end
            leaf = leaf.next_leaf
          end
        end
        
        results
      end

      def delete(key)
        if @is_leaf
          delete_from_leaf(key)
        else
          delete_from_internal(key)
        end
      end

      def delete_from_leaf(key)
        pos = find_position(key)
        
        if pos < @keys.size && @keys[pos] == key
          @keys.delete_at(pos)
          @values.delete_at(pos)
          @dirty = true
          
          # Check if node needs rebalancing
          if @keys.size < @min_keys && @parent
            return rebalance
          end
          
          self
        else
          nil
        end
      end

      def delete_from_internal(key)
        pos = find_child_position(key)
        child = @children[pos]
        
        result = child.delete(key)
        
        # Handle rebalancing
        if result == :underflow
          rebalance_child(pos)
        end
        
        self
      end

      def rebalance
        # Try to borrow from siblings
        siblings = get_siblings
        
        siblings.each do |sibling, position|
          if sibling && sibling.keys.size > @min_keys
            # Borrow from sibling
            if position < 0
              # Borrow from left sibling
              @keys.unshift(sibling.keys.last)
              @values.unshift(sibling.values.last)
              sibling.keys.pop
              sibling.values.pop
              @dirty = true
            else
              # Borrow from right sibling
              @keys.push(sibling.keys.first)
              @values.push(sibling.values.first)
              sibling.keys.shift
              sibling.values.shift
              @dirty = true
            end
            
            return self
          end
        end
        
        # Merge with a sibling
        merge_with_sibling
        :merged
      end

      def rebalance_child(pos)
        child = @children[pos]
        left_sibling = pos > 0 ? @children[pos - 1] : nil
        right_sibling = pos < @children.size - 1 ? @children[pos + 1] : nil
        
        # Try to borrow from left sibling
        if left_sibling && left_sibling.keys.size > @min_keys
          # Borrow from left sibling
          child.keys.unshift(@keys[pos - 1])
          @keys[pos - 1] = left_sibling.keys.pop
          child.values.unshift(left_sibling.values.pop) if child.is_leaf
          @dirty = true
          return
        end
        
        # Try to borrow from right sibling
        if right_sibling && right_sibling.keys.size > @min_keys
          # Borrow from right sibling
          child.keys.push(@keys[pos])
          @keys[pos] = right_sibling.keys.shift
          child.values.push(right_sibling.values.shift) if child.is_leaf
          @dirty = true
          return
        end
        
        # Merge with left sibling
        if left_sibling
          merge_nodes(left_sibling, child, pos - 1)
        elsif right_sibling
          merge_nodes(child, right_sibling, pos)
        end
      end

      def merge_nodes(left, right, parent_pos)
        # Move parent key down
        left.keys << @keys[parent_pos]
        left.values << nil unless left.is_leaf
        
        # Merge right node's keys
        left.keys.concat(right.keys)
        left.values.concat(right.values) if left.is_leaf
        left.children.concat(right.children) unless left.is_leaf
        
        # Update parent
        @keys.delete_at(parent_pos)
        @children.delete_at(parent_pos + 1)
        @dirty = true
        
        # Update leaf links
        if left.is_leaf
          left.next_leaf = right.next_leaf
          right.next_leaf.prev_leaf = left if right.next_leaf
        end
        
        # Check if parent needs rebalancing
        if @keys.size < @min_keys && @parent
          rebalance
        end
        
        :underflow
      end

      def find_position(key)
        @keys.bsearch_index { |k| k >= key } || @keys.size
      end

      def find_insert_position(key)
        @keys.bsearch_index { |k| k >= key } || @keys.size
      end

      def find_child_position(key)
        pos = @keys.bsearch_index { |k| k > key }
        pos.nil? ? @children.size - 1 : pos
      end

      def get_siblings
        siblings = []
        
        if @parent
          parent_children = @parent.children
          idx = parent_children.index(self)
          
          siblings << [idx > 0 ? parent_children[idx - 1] : nil, -1]
          siblings << [idx < parent_children.size - 1 ? parent_children[idx + 1] : nil, 1]
        end
        
        siblings
      end

      def allocate_page
        raise "B-tree page allocator is not configured" unless @page_allocator.respond_to?(:call)
        @page_allocator.call
      end

      def serialize
        {
          page_number: @page_number,
          is_leaf: @is_leaf,
          keys: @keys,
          values: @values,
          children: @children.map(&:page_number),
          next_leaf: @next_leaf&.page_number,
          prev_leaf: @prev_leaf&.page_number
        }
      end

      def self.deserialize(data)
        node = new(data[:page_number], data[:is_leaf])
        node.keys = data[:keys]
        node.values = data[:values]
        node
      end

      def to_s
        "BTreeNode(page=#{@page_number}, leaf=#{@is_leaf}, keys=#{@keys.size})"
      end

      attr_writer :keys, :values, :children
    end
  end
end
