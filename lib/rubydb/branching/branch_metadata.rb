# frozen_string_literal: true

require "json"
require "time"

module RubyDB
  module Branching
    # BranchMetadata - Manages branch metadata
    class BranchMetadata
      attr_reader :stats

      def initialize(config = {})
        @config = config
        @metadata_dir = config[:metadata_dir] || "branch_metadata"
        @metadata = {}
        @stats = {
          metadata_entries: 0,
          metadata_updated: 0,
          metadata_deleted: 0
        }
        @lock = Mutex.new

        FileUtils.mkdir_p(@metadata_dir)
        load_metadata
      end

      def set_metadata(branch_name, key, value)
        @lock.synchronize do
          @metadata[branch_name] ||= {}
          @metadata[branch_name][key] = {
            value: value,
            updated_at: Time.now.iso8601
          }
          @stats[:metadata_updated] += 1
          save_metadata
        end
      end

      def get_metadata(branch_name, key)
        @lock.synchronize do
          return nil unless @metadata[branch_name]
          @metadata[branch_name][key]&.[](:value)
        end
      end

      def get_all_metadata(branch_name)
        @lock.synchronize do
          return {} unless @metadata[branch_name]
          @metadata[branch_name].transform_values { |v| v[:value] }
        end
      end

      def delete_metadata(branch_name, key)
        @lock.synchronize do
          return false unless @metadata[branch_name]

          if @metadata[branch_name].delete(key)
            @stats[:metadata_deleted] += 1
            save_metadata
            true
          else
            false
          end
        end
      end

      def list_branches_with_metadata
        @lock.synchronize do
          @metadata.keys
        end
      end

      def get_metadata_for_branch(branch_name)
        @lock.synchronize do
          @metadata[branch_name] || {}
        end
      end

      def find_by_metadata(key, value)
        @lock.synchronize do
          results = []
          @metadata.each do |branch_name, meta|
            if meta[key] && meta[key][:value] == value
              results << branch_name
            end
          end
          results
        end
      end

      def branch_metadata_count(branch_name)
        @lock.synchronize do
          @metadata[branch_name]&.size || 0
        end
      end

      def stats
        @lock.synchronize do
          @stats.merge({
            metadata_dir: @metadata_dir,
            branches: @metadata.size,
            total_entries: @metadata.values.sum { |m| m.size }
          })
        end
      end

      private

      def load_metadata
        metadata_file = File.join(@metadata_dir, "metadata.json")
        return unless File.exist?(metadata_file)

        begin
          data = JSON.parse(File.read(metadata_file), symbolize_names: true)
          @metadata = data[:metadata] || {}
          @stats[:metadata_entries] = data[:stats][:metadata_entries] || 0
        rescue
          @metadata = {}
        end
      end

      def save_metadata
        data = {
          metadata: @metadata,
          stats: {
            metadata_entries: @stats[:metadata_entries],
            metadata_updated: @stats[:metadata_updated],
            metadata_deleted: @stats[:metadata_deleted]
          },
          updated_at: Time.now.iso8601
        }

        metadata_file = File.join(@metadata_dir, "metadata.json")
        temp_file = "#{metadata_file}.tmp"
        File.write(temp_file, JSON.generate(data))
        File.rename(temp_file, metadata_file)
      end
    end
  end
end