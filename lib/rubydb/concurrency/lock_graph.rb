# frozen_string_literal: true

require "set"

module RubyDB
  module Concurrency
    # LockGraph - Represents the wait-for graph for deadlock detection
    class LockGraph
      attr_reader :nodes, :edges

      def initialize
        @nodes = {}  # transaction_id => {locks: [], waiting_for: []}
        @edges = {}  # source => {target: edge_info}
        @reverse_edges = {}  # target => [sources]
        @lock = Mutex.new
      end

      def add_holder(resource, holder)
        @lock.synchronize do
          @nodes[holder[:id]] ||= {
            id: holder[:id],
            locks: [],
            waiting_for: [],
            info: holder
          }
          @nodes[holder[:id]][:locks] << resource
        end
      end

      def add_waiter(resource, waiter)
        @lock.synchronize do
          @nodes[waiter[:id]] ||= {
            id: waiter[:id],
            locks: [],
            waiting_for: [],
            info: waiter
          }
          @nodes[waiter[:id]][:waiting_for] << resource

          # Find who holds the resource
          holders = find_holders(resource)
          holders.each do |holder|
            add_edge(waiter[:id], holder[:id], resource)
          end
        end
      end

      def remove_transaction(transaction_id)
        @lock.synchronize do
          # Remove all edges involving this transaction
          @edges.delete(transaction_id)
          @reverse_edges.delete(transaction_id)

          @edges.each do |source, targets|
            targets.delete(transaction_id)
          end

          @reverse_edges.each do |target, sources|
            sources.delete(transaction_id)
          end

          @nodes.delete(transaction_id)
        end
      end

      def release_locks(transaction_id)
        @lock.synchronize do
          node = @nodes[transaction_id]
          return unless node

          # Remove all resources locked by this transaction
          node[:locks].clear
          node[:waiting_for].clear

          # Clean up edges
          remove_transaction(transaction_id)
        end
      end

      def build
        @lock.synchronize do
          # Rebuild graph from current state
          # This would be called periodically
          true
        end
      end

      def detect_cycles
        @lock.synchronize do
          cycles = []
          visited = Set.new
          recursion_stack = Set.new

          @nodes.each_key do |node|
            if !visited.include?(node)
              path = []
              if detect_cycle_dfs(node, visited, recursion_stack, path)
                cycles << path
              end
            end
          end

          cycles
        end
      end

      def size
        @nodes.size
      end

      def edge_count
        @edges.values.sum(&:size)
      end

      def to_s
        "LockGraph(nodes=#{@nodes.size}, edges=#{edge_count})"
      end

      private

      def find_holders(resource)
        holders = []
        @nodes.each do |id, node|
          if node[:locks].include?(resource)
            holders << { id: id, info: node[:info] }
          end
        end
        holders
      end

      def add_edge(source, target, resource)
        @edges[source] ||= {}
        @edges[source][target] = { resource: resource, timestamp: Time.now }

        @reverse_edges[target] ||= Set.new
        @reverse_edges[target] << source
      end

      def detect_cycle_dfs(node, visited, recursion_stack, path)
        return false if visited.include?(node)

        visited.add(node)
        recursion_stack.add(node)
        path << node

        @edges[node]&.keys&.each do |neighbor|
          if recursion_stack.include?(neighbor)
            # Found a cycle
            cycle_start = path.index(neighbor)
            cycle = path[cycle_start..-1] + [neighbor]
            return true
          end

          if detect_cycle_dfs(neighbor, visited, recursion_stack, path)
            return true
          end
        end

        recursion_stack.delete(node)
        path.pop
        false
      end
    end
  end
end