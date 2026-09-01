# frozen_string_literal: true

require "fileutils"
require "json"

module RubyDB
  module Branching
    # CopyOnWrite - Manages copy-on-write for branches
    class CopyOnWrite
      attr_reader :stats

      def initialize(engine, config = {})
        @engine = engine
        @config = config
        @cow_dir = config[:cow_dir] || "cow"
        @branch_data = {}
        @stats = {
          cow_files_created: 0,
          cow_files_accessed: 0,
          cow_files_updated: 0,
          cow_files_deleted: 0,
          total_cow_size: 0
        }
        @lock = Mutex.new

        FileUtils.mkdir_p(@cow_dir)
        load_cow_data
      end

      def create_cow(branch_name, base_path)
        @lock.synchronize do
          cow_path = File.join(@cow_dir, branch_name)
          FileUtils.mkdir_p(cow_path)

          # Create COW for each file
          files = Dir.glob(File.join(base_path, "**/*"))
          files.each do |file|
            next unless File.file?(file)

            relative_path = file.sub(base_path + "/", "")
            cow_file = File.join(cow_path, relative_path)
            FileUtils.mkdir_p(File.dirname(cow_file))

            # Create hard link or copy
            begin
              File.link(file, cow_file)
            rescue
              FileUtils.cp(file, cow_file)
            end

            @stats[:cow_files_created] += 1
            @stats[:total_cow_size] += File.size(cow_file)
          end

          @branch_data[branch_name] = {
            base_path: base_path,
            cow_path: cow_path,
            created_at: Time.now.iso8601,
            files: files.map { |f| f.sub(base_path + "/", "") }
          }

          save_cow_data

          { success: true, cow_path: cow_path, file_count: files.size }
        end
      end

      def read_file(branch_name, file_path)
        @lock.synchronize do
          cow_path = File.join(@cow_dir, branch_name)
          cow_file = File.join(cow_path, file_path)

          if File.exist?(cow_file)
            @stats[:cow_files_accessed] += 1
            return File.read(cow_file)
          end

          # Read from base
          branch_data = @branch_data[branch_name]
          return nil unless branch_data

          base_file = File.join(branch_data[:base_path], file_path)
          return nil unless File.exist?(base_file)

          File.read(base_file)
        end
      end

      def write_file(branch_name, file_path, content)
        @lock.synchronize do
          cow_path = File.join(@cow_dir, branch_name)
          cow_file = File.join(cow_path, file_path)
          FileUtils.mkdir_p(File.dirname(cow_file))

          File.write(cow_file, content)
          @stats[:cow_files_updated] += 1

          # Update branch data
          @branch_data[branch_name] ||= { files: [] }
          unless @branch_data[branch_name][:files].include?(file_path)
            @branch_data[branch_name][:files] << file_path
          end

          save_cow_data

          { success: true, path: cow_file }
        end
      end

      def delete_file(branch_name, file_path)
        @lock.synchronize do
          cow_path = File.join(@cow_dir, branch_name)
          cow_file = File.join(cow_path, file_path)

          if File.exist?(cow_file)
            File.delete(cow_file)
            @stats[:cow_files_deleted] += 1

            # Update branch data
            if @branch_data[branch_name]
              @branch_data[branch_name][:files].delete(file_path)
            end

            save_cow_data
            return { success: true }
          end

          { success: false, error: "File not found in COW" }
        end
      end

      def list_cow_files(branch_name)
        @lock.synchronize do
          cow_path = File.join(@cow_dir, branch_name)
          return [] unless Dir.exist?(cow_path)

          Dir.glob(File.join(cow_path, "**/*")).select do |f|
            File.file?(f)
          end.map { |f| f.sub(cow_path + "/", "") }
        end
      end

      def delete_branch_cow(branch_name)
        @lock.synchronize do
          cow_path = File.join(@cow_dir, branch_name)
          if Dir.exist?(cow_path)
            size = calculate_dir_size(cow_path)
            FileUtils.rm_rf(cow_path)
            @stats[:total_cow_size] -= size
            @stats[:cow_files_deleted] += 1
          end

          @branch_data.delete(branch_name)
          save_cow_data

          { success: true }
        end
      end

      def snapshot(branch_name, snapshot_name)
        @lock.synchronize do
          cow_path = File.join(@cow_dir, branch_name)
          return { success: false, error: "Branch COW not found" } unless Dir.exist?(cow_path)

          snapshot_path = File.join(@cow_dir, "snapshots", snapshot_name)
          FileUtils.mkdir_p(File.dirname(snapshot_path))

          # Copy all COW files
          FileUtils.cp_r(cow_path, snapshot_path)

          { success: true, snapshot_path: snapshot_path }
        end
      end

      def restore_snapshot(snapshot_name, branch_name)
        @lock.synchronize do
          snapshot_path = File.join(@cow_dir, "snapshots", snapshot_name)
          return { success: false, error: "Snapshot not found" } unless Dir.exist?(snapshot_path)

          cow_path = File.join(@cow_dir, branch_name)
          FileUtils.rm_rf(cow_path) if Dir.exist?(cow_path)
          FileUtils.cp_r(snapshot_path, cow_path)

          { success: true }
        end
      end

      def stats
        @lock.synchronize do
          @stats.merge({
            branches: @branch_data.size,
            cow_dir: @cow_dir,
            snapshots: Dir.glob(File.join(@cow_dir, "snapshots", "*")).size
          })
        end
      end

      private

      def load_cow_data
        data_file = File.join(@cow_dir, "cow_data.json")
        return unless File.exist?(data_file)

        begin
          data = JSON.parse(File.read(data_file), symbolize_names: true)
          @branch_data = data[:branch_data] || {}
          @stats = data[:stats] || @stats
        rescue
          @branch_data = {}
        end
      end

      def save_cow_data
        data = {
          branch_data: @branch_data,
          stats: @stats,
          updated_at: Time.now.iso8601
        }

        data_file = File.join(@cow_dir, "cow_data.json")
        temp_file = "#{data_file}.tmp"
        File.write(temp_file, JSON.generate(data))
        File.rename(temp_file, data_file)
      end

      def calculate_dir_size(path)
        Dir.glob(File.join(path, "**/*")).sum do |f|
          File.size(f) if File.file?(f)
        end || 0
      end
    end
  end
end