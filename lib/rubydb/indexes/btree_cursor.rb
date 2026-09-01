# frozen_string_literal: true

module RubyDB
  module Indexes
    # B-Tree cursor for sequential access
    class BTreeCursor
      attr_reader :btree, :current_key, :current_value, :position

      def initialize(btree)
        @btree = btree
        @current_key = nil
        @current_value = nil
        @position = 0
        @stack = []
        @direction = :forward
        @started = false
        @finished = false
      end

      def first
        lock.synchronize do
          reset
          @direction = :forward
          move_to_first
          @started = true
          @current_key
        end
      end

      def last
        lock.synchronize do
          reset
          @direction = :backward
          move_to_last
          @started = true
          @current_key
        end
      end

      def next
        lock.synchronize do
          return nil if @finished
          return first if !@started
          
          if @direction == :backward
            @direction = :forward
          end
          
          move_next
          
          if @current_key.nil?
            @finished = true
            nil
          else
            { key: @current_key, value: @current_value }
          end
        end
      end

      def prev
        lock.synchronize do
          return nil if @finished
          return last if !@started
          
          if @direction == :forward
            @direction = :backward
          end
          
          move_prev
          
          if @current_key.nil?
            @finished = true
            nil
          else
            { key: @current_key, value: @current_value }
          end
        end
      end

      def seek(key)
        lock.synchronize do
          reset
          @direction = :forward
          
          node = @btree.root
          find_node(node, key)
          
          @started = true
          @current_key
        end
      end

      def reset
        @current_key = nil
        @current_value = nil
        @position = 0
        @stack.clear
        @started = false
        @finished = false
      end

      private

      def move_to_first
        node = @btree.root
        return unless node
        
        while !node.is_leaf
          @stack << { node: node, position: 0 }
          node = node.children.first
        end
        
        if node.keys.any?
          @current_key = node.keys.first
          @current_value = node.values.first
          @stack << { node: node, position: 0 }
        end
      end

      def move_to_last
        node = @btree.root
        return unless node
        
        while !node.is_leaf
          @stack << { node: node, position: node.children.size - 1 }
          node = node.children.last
        end
        
        if node.keys.any?
          pos = node.keys.size - 1
          @current_key = node.keys[pos]
          @current_value = node.values[pos]
          @stack << { node: node, position: pos }
        end
      end

      def move_next
        if @stack.empty?
          @current_key = nil
          @current_value = nil
          return
        end
        
        current_frame = @stack.last
        node = current_frame[:node]
        pos = current_frame[:position]
        
        # Move to next key in current node
        if pos + 1 < node.keys.size
          current_frame[:position] = pos + 1
          @current_key = node.keys[pos + 1]
          @current_value = node.values[pos + 1]
          return
        end
        
        # Move up the stack
        while @stack.size > 1
          @stack.pop
          parent = @stack.last
          parent_pos = parent[:position]
          
          # Check if parent has next child
          if parent_pos + 1 < parent[:node].children.size
            # Go down to next leaf
            parent[:position] = parent_pos + 1
            node = parent[:node].children[parent_pos + 1]
            
            while !node.is_leaf
              @stack << { node: node, position: 0 }
              node = node.children.first
            end
            
            @stack << { node: node, position: 0 }
            @current_key = node.keys.first
            @current_value = node.values.first
            return
          end
        end
        
        # Reached end
        @current_key = nil
        @current_value = nil
      end

      def move_prev
        if @stack.empty?
          @current_key = nil
          @current_value = nil
          return
        end
        
        current_frame = @stack.last
        node = current_frame[:node]
        pos = current_frame[:position]
        
        # Move to previous key in current node
        if pos - 1 >= 0
          current_frame[:position] = pos - 1
          @current_key = node.keys[pos - 1]
          @current_value = node.values[pos - 1]
          return
        end
        
        # Move up the stack
        while @stack.size > 1
          @stack.pop
          parent = @stack.last
          parent_pos = parent[:position]
          
          # Check if parent has previous child
          if parent_pos - 1 >= 0
            parent[:position] = parent_pos - 1
            node = parent[:node].children[parent_pos - 1]
            
            while !node.is_leaf
              @stack << { node: node, position: node.children.size - 1 }
              node = node.children.last
            end
            
            pos = node.keys.size - 1
            @stack << { node: node, position: pos }
            @current_key = node.keys[pos]
            @current_value = node.values[pos]
            return
          end
        end
        
        # Reached beginning
        @current_key = nil
        @current_value = nil
      end

      def find_node(node, key)
        if node.is_leaf
          pos = node.find_position(key)
          if pos < node.keys.size && node.keys[pos] == key
            @current_key = node.keys[pos]
            @current_value = node.values[pos]
            @stack << { node: node, position: pos }
          else
            # Key not found - position at insertion point
            @current_key = nil
            @current_value = nil
            @finished = true
          end
        else
          pos = node.find_child_position(key)
          @stack << { node: node, position: pos }
          find_node(node.children[pos], key)
        end
      end

      def lock
        @btree.instance_variable_get(:@lock)
      end
    end
  end
end