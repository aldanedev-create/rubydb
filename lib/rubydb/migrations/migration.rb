# frozen_string_literal: true

require "time"
require "json"

module RubyDB
  module Migrations
    # Migration - Represents a single database migration
    class Migration
      attr_reader :version, :name, :description, :up_operations
      attr_reader :down_operations, :created_at, :applied_at
      attr_reader :author, :dependencies, :checksum

      # Migration states
      STATE_PENDING = :pending
      STATE_APPLIED = :applied
      STATE_FAILED = :failed
      STATE_ROLLED_BACK = :rolled_back

      def initialize(version, name, options = {})
        @version = version
        @name = name
        @description = options[:description] || ""
        @up_operations = []
        @down_operations = []
        @created_at = Time.now
        @applied_at = nil
        @state = STATE_PENDING
        @author = options[:author]
        @dependencies = options[:dependencies] || []
        @checksum = nil
        @metadata = options[:metadata] || {}
      end

      def up(&block)
        if block_given?
          @up_operations << block
        end
        self
      end

      def down(&block)
        if block_given?
          @down_operations << block
        end
        self
      end

      def apply_up(engine)
        @up_operations.each do |operation|
          operation.call(engine)
        end
        @state = STATE_APPLIED
        @applied_at = Time.now
        calculate_checksum
      end

      def apply_down(engine)
        @down_operations.reverse_each do |operation|
          operation.call(engine)
        end
        @state = STATE_ROLLED_BACK
      end

      def applied?
        @state == STATE_APPLIED
      end

      def pending?
        @state == STATE_PENDING
      end

      def failed?
        @state == STATE_FAILED
      end

      def rolled_back?
        @state == STATE_ROLLED_BACK
      end

      def mark_failed
        @state = STATE_FAILED
      end

      def to_sql
        # Generate SQL from operations (simplified)
        "MIGRATION #{@version}: #{@name}"
      end

      def to_hash
        {
          version: @version,
          name: @name,
          description: @description,
          created_at: @created_at.iso8601,
          applied_at: @applied_at&.iso8601,
          state: @state,
          author: @author,
          dependencies: @dependencies,
          checksum: @checksum,
          metadata: @metadata,
          up_operations_count: @up_operations.size,
          down_operations_count: @down_operations.size
        }
      end

      def to_json
        JSON.generate(to_hash)
      end

      def self.from_json(json_data)
        data = JSON.parse(json_data, symbolize_names: true)
        migration = new(data[:version], data[:name],
          description: data[:description],
          author: data[:author],
          dependencies: data[:dependencies] || [],
          metadata: data[:metadata] || {}
        )
        migration.instance_variable_set(:@created_at, Time.parse(data[:created_at]))
        migration.instance_variable_set(:@applied_at, Time.parse(data[:applied_at])) if data[:applied_at]
        migration.instance_variable_set(:@state, data[:state].to_sym)
        migration.instance_variable_set(:@checksum, data[:checksum])
        migration
      end

      def inspect
        "#<Migration version=#{@version} name=#{@name} state=#{@state}>"
      end

      private

      def calculate_checksum
        data = @up_operations.map(&:to_s).join + @down_operations.map(&:to_s).join
        @checksum = Digest::SHA256.hexdigest(data)[0...16]
      end
    end
  end
end