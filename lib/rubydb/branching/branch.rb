# frozen_string_literal: true

require "time"
require "securerandom"

module RubyDB
  module Branching
    # Branch - Represents a database branch
    class Branch
      attr_reader :name, :id, :created_at, :updated_at, :metadata, :changes, :state_snapshot
      attr_accessor :parent_branch, :head_lsn, :base_lsn, :state

      # Branch states
      STATE_ACTIVE = :active
      STATE_MERGED = :merged
      STATE_ABANDONED = :abandoned
      STATE_ARCHIVED = :archived
      STATE_LOCKED = :locked

      def initialize(name, options = {})
        @name = name
        @id = options[:id] || generate_branch_id
        @parent_branch = options[:parent_branch]
        @base_lsn = options[:base_lsn] || 0
        @head_lsn = @base_lsn
        @created_at = Time.now
        @updated_at = Time.now
        @state = STATE_ACTIVE
        @metadata = options[:metadata] || {}
        @description = options[:description]
        @owner = options[:owner]
        @is_protected = options[:protected] || false
        @is_default = options[:default] || false
        @changes = []
        @state_snapshot = options[:state_snapshot]
        @commit_count = 0
        @last_commit = nil
        @lock = Mutex.new
      end

      def commit(change)
        @lock.synchronize do
          @changes << change
          @commit_count += 1
          @head_lsn = change[:lsn] if change[:lsn]
          @last_commit = Time.now
          @updated_at = Time.now
        end
      end

      def changes
        @lock.synchronize { @changes.map(&:dup) }
      end

      def logical_changes
        @lock.synchronize do
          @changes.map do |change|
            payload = change[:data] || change["data"]
            (payload.is_a?(Hash) ? payload : change).dup
          end
        end
      end

      def rollback(count = 1)
        @lock.synchronize do
          return false if @changes.empty?

          removed = @changes.pop(count)
          @commit_count -= removed.size
          @head_lsn = @changes.last&.[](:lsn) || @base_lsn
          @updated_at = Time.now

          removed
        end
      end

      def merge_changes(changes)
        @lock.synchronize do
          changes.each do |change|
            @changes << change
            @commit_count += 1
            @head_lsn = change[:lsn] if change[:lsn]
          end
          @last_commit = Time.now
          @updated_at = Time.now
        end
      end

      def lock
        @lock.synchronize do
          @state = STATE_LOCKED
          @updated_at = Time.now
        end
      end

      def unlock
        @lock.synchronize do
          @state = STATE_ACTIVE if @state == STATE_LOCKED
          @updated_at = Time.now
        end
      end

      def archive
        @lock.synchronize do
          @state = STATE_ARCHIVED
          @updated_at = Time.now
        end
      end

      def merge
        @lock.synchronize do
          @state = STATE_MERGED
          @updated_at = Time.now
        end
      end

      def abandon
        @lock.synchronize do
          @state = STATE_ABANDONED
          @updated_at = Time.now
        end
      end

      def active?
        @state == STATE_ACTIVE
      end

      def merged?
        @state == STATE_MERGED
      end

      def locked?
        @state == STATE_LOCKED
      end

      def archived?
        @state == STATE_ARCHIVED
      end

      def abandoned?
        @state == STATE_ABANDONED
      end

      def change_count
        @changes.size
      end

      def to_hash
        {
          name: @name,
          id: @id,
          parent_branch: @parent_branch,
          base_lsn: @base_lsn,
          head_lsn: @head_lsn,
          created_at: @created_at.iso8601,
          updated_at: @updated_at.iso8601,
          state: @state,
          commit_count: @commit_count,
          last_commit: @last_commit&.iso8601,
          is_protected: @is_protected,
          is_default: @is_default,
          owner: @owner,
          description: @description,
          metadata: @metadata,
          changes: @changes,
          state_snapshot: @state_snapshot
        }
      end

      def inspect
        "#<Branch name=#{@name} state=#{@state} commits=#{@commit_count}>"
      end

      private

      def generate_branch_id
        "br_#{Time.now.to_i}_#{SecureRandom.hex(8)}"
      end
    end
  end
end
