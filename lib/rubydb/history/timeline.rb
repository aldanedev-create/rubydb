# frozen_string_literal: true

require "time"

module RubyDB
  module History
    # Timeline - Manages a timeline of changes
    class Timeline
      attr_reader :name, :changes, :created_at, :updated_at

      def initialize(name, changes = [])
        @name = name
        @changes = changes
        @created_at = Time.now
        @updated_at = Time.now
        @position = changes.size
        @lock = Mutex.new
      end

      def add_change(change)
        @lock.synchronize do
          @changes << change
          @position = @changes.size
          @updated_at = Time.now
        end
      end

      def get_change_at(index)
        @lock.synchronize do
          @changes[index]
        end
      end

      def get_changes_between(start_time, end_time)
        @lock.synchronize do
          @changes.select do |c|
            c.timestamp >= start_time && c.timestamp <= end_time
          end
        end
      end

      def get_changes_for_table(table_name)
        @lock.synchronize do
          @changes.select { |c| c.table_name == table_name }
        end
      end

      def get_changes_for_row(table_name, row_id)
        @lock.synchronize do
          @changes.select { |c| c.table_name == table_name && c.row_id == row_id }
        end
      end

      def get_changes_by_operation(operation)
        @lock.synchronize do
          @changes.select { |c| c.operation == operation }
        end
      end

      def get_changes_by_user(user)
        @lock.synchronize do
          @changes.select { |c| c.user == user }
        end
      end

      def get_changes_by_branch(branch)
        @lock.synchronize do
          @changes.select { |c| c.branch == branch }
        end
      end

      def get_changes_by_lsn_range(start_lsn, end_lsn)
        @lock.synchronize do
          @changes.select { |c| c.lsn >= start_lsn && c.lsn <= end_lsn }
        end
      end

      def rollback_to(index)
        @lock.synchronize do
          return false if index < 0 || index >= @changes.size

          # Remove changes after index
          @changes = @changes[0..index]
          @position = @changes.size
          @updated_at = Time.now

          true
        end
      end

      def rollback_to_time(time)
        @lock.synchronize do
          index = @changes.rindex { |c| c.timestamp <= time }
          return false unless index

          rollback_to(index)
        end
      end

      def size
        @changes.size
      end

      def empty?
        @changes.empty?
      end

      def last_change
        @changes.last
      end

      def first_change
        @changes.first
      end

      def to_hash
        {
          name: @name,
          changes: @changes.map(&:to_hash),
          created_at: @created_at.iso8601,
          updated_at: @updated_at.iso8601,
          size: @changes.size
        }
      end

      def to_json
        JSON.generate(to_hash)
      end

      def self.from_json(json_data)
        data = JSON.parse(json_data, symbolize_names: true)
        changes = data[:changes].map { |c| Change.from_json(c.to_json) }
        timeline = new(data[:name], changes)
        timeline.instance_variable_set(:@created_at, Time.parse(data[:created_at]))
        timeline.instance_variable_set(:@updated_at, Time.parse(data[:updated_at]))
        timeline
      end

      def inspect
        "#<Timeline name=#{@name} changes=#{@changes.size}>"
      end
    end
  end
end