# frozen_string_literal: true

module RubyDB
  module Client
    # Transaction - Database transaction
    class Transaction
      attr_reader :id, :client, :started_at, :options

      def initialize(client, options = {})
        @client = client
        @options = options
        @id = "txn_#{Time.now.to_i}_#{rand(1000)}"
        @started_at = Time.now
        @active = true
        @committed = false
        @rolled_back = false
        @savepoints = []
        @lock = Mutex.new
      end

      def query(sql, params = [])
        @lock.synchronize do
          raise ClientError, "Transaction is not active" unless @active
          @client.query(sql, params)
        end
      end

      def prepare(sql)
        @lock.synchronize do
          raise ClientError, "Transaction is not active" unless @active
          @client.prepare(sql)
        end
      end

      def execute(statement_id, params = [])
        @lock.synchronize do
          raise ClientError, "Transaction is not active" unless @active
          @client.execute(statement_id, params)
        end
      end

      def savepoint(name)
        @lock.synchronize do
          raise ClientError, "Transaction is not active" unless @active
          @savepoints << name
          @client.query("SAVEPOINT #{name}")
        end
      end

      def rollback_to_savepoint(name)
        @lock.synchronize do
          raise ClientError, "Transaction is not active" unless @active
          unless @savepoints.include?(name)
            raise ClientError, "Savepoint '#{name}' not found"
          end
          @client.query("ROLLBACK TO SAVEPOINT #{name}")
          @savepoints.delete(name)
        end
      end

      def release_savepoint(name)
        @lock.synchronize do
          raise ClientError, "Transaction is not active" unless @active
          unless @savepoints.include?(name)
            raise ClientError, "Savepoint '#{name}' not found"
          end
          @client.query("RELEASE SAVEPOINT #{name}")
          @savepoints.delete(name)
        end
      end

      def commit
        @lock.synchronize do
          raise ClientError, "Transaction is not active" unless @active
          @client.commit
          @active = false
          @committed = true
        end
      end

      def rollback
        @lock.synchronize do
          raise ClientError, "Transaction is not active" unless @active
          @client.rollback
          @active = false
          @rolled_back = true
        end
      end

      def active?
        @active
      end

      def committed?
        @committed
      end

      def rolled_back?
        @rolled_back
      end

      def to_hash
        {
          id: @id,
          started_at: @started_at.iso8601,
          active: @active,
          committed: @committed,
          rolled_back: @rolled_back,
          savepoints: @savepoints,
          options: @options
        }
      end

      def inspect
        "#<Transaction id=#{@id} active=#{@active}>"
      end
    end
  end
end