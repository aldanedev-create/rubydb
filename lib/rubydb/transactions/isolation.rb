# frozen_string_literal: true

module RubyDB
  module Transactions
    # Isolation - Defines isolation levels and their behaviors
    module Isolation
      # Isolation levels
      READ_UNCOMMITTED = :read_uncommitted
      READ_COMMITTED = :read_committed
      REPEATABLE_READ = :repeatable_read
      SERIALIZABLE = :serializable

      # Phenomena that can occur at each isolation level
      PHENOMENA = {
        READ_UNCOMMITTED => {
          dirty_reads: true,
          non_repeatable_reads: true,
          phantom_reads: true,
          serialization_anomalies: true
        },
        READ_COMMITTED => {
          dirty_reads: false,
          non_repeatable_reads: true,
          phantom_reads: true,
          serialization_anomalies: true
        },
        REPEATABLE_READ => {
          dirty_reads: false,
          non_repeatable_reads: false,
          phantom_reads: true,
          serialization_anomalies: true
        },
        SERIALIZABLE => {
          dirty_reads: false,
          non_repeatable_reads: false,
          phantom_reads: false,
          serialization_anomalies: false
        }
      }

      def self.dirty_reads_allowed?(level)
        PHENOMENA[level][:dirty_reads]
      end

      def self.non_repeatable_reads_allowed?(level)
        PHENOMENA[level][:non_repeatable_reads]
      end

      def self.phantom_reads_allowed?(level)
        PHENOMENA[level][:phantom_reads]
      end

      def self.serialization_anomalies_allowed?(level)
        PHENOMENA[level][:serialization_anomalies]
      end

      def self.isolation_level_name(level)
        level.to_s.upcase
      end

      def self.valid_level?(level)
        PHENOMENA.key?(level)
      end

      def self.default_level
        READ_COMMITTED
      end

      def self.highest_level
        SERIALIZABLE
      end

      def self.lowest_level
        READ_UNCOMMITTED
      end

      def self.next_higher(level)
        case level
        when READ_UNCOMMITTED then READ_COMMITTED
        when READ_COMMITTED then REPEATABLE_READ
        when REPEATABLE_READ then SERIALIZABLE
        when SERIALIZABLE then SERIALIZABLE
        else default_level
        end
      end

      def self.next_lower(level)
        case level
        when SERIALIZABLE then REPEATABLE_READ
        when REPEATABLE_READ then READ_COMMITTED
        when READ_COMMITTED then READ_UNCOMMITTED
        when READ_UNCOMMITTED then READ_UNCOMMITTED
        else default_level
        end
      end
    end
  end
end