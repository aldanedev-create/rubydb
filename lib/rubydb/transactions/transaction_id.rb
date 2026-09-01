# frozen_string_literal: true

module RubyDB
  module Transactions
    # TransactionId - Represents a unique transaction identifier
    class TransactionId
      attr_reader :id, :timestamp, :sequence

      def initialize(id = nil, timestamp = nil, sequence = nil)
        if id
          @id = id
          parse_id(id)
        else
          @timestamp = timestamp || Time.now
          @sequence = sequence || 0
          @id = generate_id
        end
      end

      def to_s
        @id
      end

      def to_i
        @id.hash
      end

      def ==(other)
        other.is_a?(TransactionId) && @id == other.id
      end

      def eql?(other)
        self == other
      end

      def hash
        @id.hash
      end

      def <=>(other)
        return nil unless other.is_a?(TransactionId)
        @timestamp <=> other.timestamp
      end

      def <(other)
        return false unless other.is_a?(TransactionId)
        @timestamp < other.timestamp
      end

      def >(other)
        return false unless other.is_a?(TransactionId)
        @timestamp > other.timestamp
      end

      def inspect
        "#<TransactionId id=#{@id} timestamp=#{@timestamp}>"
      end

      def serialize
        @id
      end

      def self.deserialize(id)
        new(id)
      end

      private

      def generate_id
        "txn_#{@timestamp.to_i}_#{@sequence}"
      end

      def parse_id(id)
        if id =~ /txn_(\d+)_(\d+)/
          @timestamp = Time.at($1.to_i)
          @sequence = $2.to_i
        else
          @timestamp = Time.now
          @sequence = 0
        end
      end
    end
  end
end