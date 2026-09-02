# frozen_string_literal: true

require "fileutils"
require "json"
require "pathname"

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
          cow_path = branch_path(branch_name)
          return { success: false, error: "Invalid branch name" } unless cow_path
          base_root = File.expand_path(base_path)
          return { success: false, error: "Base path does not exist" } unless Dir.exist?(base_root)
          FileUtils.mkdir_p(cow_path)

          # Create COW for each file
          files = Dir.glob(File.join(base_root, "**/*")).select { |file| File.file?(file) }
          files.each do |file|
            relative_path = Pathname.new(file).relative_path_from(Pathname.new(base_root)).to_s
            cow_file = nested_path(cow_path, relative_path)
            raise "Invalid source path for copy-on-write" unless cow_file
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
            base_path: base_root,
            cow_path: cow_path,
            created_at: Time.now.iso8601,
            files: files.map { |file| Pathname.new(file).relative_path_from(Pathname.new(base_root)).to_s }
          }

          save_cow_data

          { success: true, cow_path: cow_path, file_count: files.size }
        end
      end

      def read_file(branch_name, file_path)
        @lock.synchronize do
          cow_path = branch_path(branch_name)
          cow_file = cow_path && nested_path(cow_path, file_path)
          return nil unless cow_file

          if File.exist?(cow_file)
            @stats[:cow_files_accessed] += 1
            return File.read(cow_file)
          end

          # Read from base
          branch_data = @branch_data[branch_name]
          return nil unless branch_data

          base_file = nested_path(branch_data[:base_path], file_path)
          return nil unless File.exist?(base_file)

          File.read(base_file)
        end
      end

      def write_file(branch_name, file_path, content)
        @lock.synchronize do
          cow_path = branch_path(branch_name)
          cow_file = cow_path && nested_path(cow_path, file_path)
          return { success: false, error: "Invalid branch name or file path" } unless cow_file
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
          cow_path = branch_path(branch_name)
          cow_file = cow_path && nested_path(cow_path, file_path)
          return { success: false, error: "Invalid branch name or file path" } unless cow_file

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
          cow_path = branch_path(branch_name)
          return [] unless cow_path
          return [] unless Dir.exist?(cow_path)

          Dir.glob(File.join(cow_path, "**/*")).select do |f|
            File.file?(f)
          end.map { |f| f.sub(cow_path + "/", "") }
        end
      end

      def delete_branch_cow(branch_name)
        @lock.synchronize do
          cow_path = branch_path(branch_name)
          return { success: false, error: "Invalid branch name" } unless cow_path
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
          cow_path = branch_path(branch_name)
          return { success: false, error: "Invalid branch name" } unless cow_path
          return { success: false, error: "Branch COW not found" } unless Dir.exist?(cow_path)

          snapshot_path = snapshot_path(snapshot_name)
          return { success: false, error: "Invalid snapshot name" } unless snapshot_path
          FileUtils.mkdir_p(File.dirname(snapshot_path))

          # Copy all COW files
          FileUtils.cp_r(cow_path, snapshot_path)

          { success: true, snapshot_path: snapshot_path }
        end
      end

      def restore_snapshot(snapshot_name, branch_name)
        @lock.synchronize do
          snapshot_path = snapshot_path(snapshot_name)
          return { success: false, error: "Invalid snapshot name" } unless snapshot_path
          return { success: false, error: "Snapshot not found" } unless Dir.exist?(snapshot_path)

          cow_path = branch_path(branch_name)
          return { success: false, error: "Invalid branch name" } unless cow_path
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

      def branch_path(branch_name)
        name = branch_name.to_s
        return nil unless safe_name?(name)

        nested_path(@cow_dir, name)
      end

      def snapshot_path(snapshot_name)
        name = snapshot_name.to_s
        return nil unless safe_name?(name)

        nested_path(File.join(@cow_dir, "snapshots"), name)
      end

      def safe_name?(name)
        !name.empty? && name == File.basename(name) && !Pathname.new(name).absolute?
      end

      def nested_path(root_path, relative_path)
        relative = relative_path.to_s
        return nil if relative.empty? || Pathname.new(relative).absolute?

        root = File.expand_path(root_path)
        path = File.expand_path(File.join(root, relative))
        path.start_with?("#{root}#{File::SEPARATOR}") ? path : nil
      end

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
