# frozen_string_literal: true

module RubyDB
  module Rails
    # Transaction - Transaction management for Rails
    class Transaction
      attr_reader :connection, :depth, :state

      def initialize(connection)
        @connection = connection
        @depth = 0
        @state = :active
        @savepoints = []
        @lock = Mutex.new
      end

      def begin
        @lock.synchronize do
          return false if @state != :active

          @connection.begin_db_transaction
          @depth += 1
          true
        end
      end

      def commit
        @lock.synchronize do
          return false if @state == :committed || @state == :rolled_back

          @connection.commit_db_transaction
          @depth -= 1
          @state = :committed if @depth == 0
          true
        end
      end

      def rollback
        @lock.synchronize do
          return false if @state == :committed || @state == :rolled_back

          @connection.rollback_db_transaction
          @depth = 0
          @state = :rolled_back
          true
        end
      end

      def create_savepoint(name)
        @lock.synchronize do
          return false if @state != :active

          @connection.execute("SAVEPOINT #{name}")
          @savepoints << name
          true
        end
      end

      def rollback_to_savepoint(name)
        @lock.synchronize do
          return false if @state != :active

          unless @savepoints.include?(name)
            return false
          end

          @connection.execute("ROLLBACK TO SAVEPOINT #{name}")
          @savepoints = @savepoints[0...@savepoints.index(name)]
          true
        end
      end

      def release_savepoint(name)
        @lock.synchronize do
          return false if @state != :active

          unless @savepoints.include?(name)
            return false
          end

          @connection.execute("RELEASE SAVEPOINT #{name}")
          @savepoints.delete(name)
          true
        end
      end

      def active?
        @state == :active
      end

      def in_progress?
        @depth > 0
      end

      def to_hash
        {
          depth: @depth,
          state: @state,
          savepoints: @savepoints,
          in_progress: in_progress?
        }
      end
    end
  end
end