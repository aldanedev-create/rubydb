# frozen_string_literal: true

require "fileutils"
require "json"
require "time"

module RubyDB
  module Branching
    # BranchManager - Manages all database branches
    class BranchManager
      attr_reader :branches, :current_branch, :stats

      def initialize(engine, config = {})
        @engine = engine
        @config = config
        @branches = {}
        @current_branch = nil
        @branch_dir = config[:branch_dir] || "branches"
        @stats = {
          branches_created: 0,
          branches_deleted: 0,
          branches_merged: 0,
          branches_abandoned: 0,
          total_commits: 0,
          active_branches: 0
        }
        @lock = Mutex.new

        FileUtils.mkdir_p(@branch_dir)

        # Load existing branches
        load_branches

        # Create default branch if none exists
        create_default_branch if @branches.empty?
      end

      def create_branch(name, options = {})
        @lock.synchronize do
          if @branches.key?(name)
            return { success: false, error: "Branch '#{name}' already exists" }
          end

          parent = options[:from] || @current_branch&.name
          parent_branch = parent ? @branches[parent] : nil

          unless parent_branch || options[:from_lsn]
            return { success: false, error: "No parent branch or LSN specified" }
          end

          base_lsn = options[:from_lsn] || parent_branch.head_lsn

          branch = Branch.new(name,
            parent_branch: parent,
            base_lsn: base_lsn,
            description: options[:description],
            owner: options[:owner],
            protected: options[:protected] || false,
            default: options[:default] || false,
            metadata: options[:metadata] || {}
          )

          @branches[name] = branch
          @stats[:branches_created] += 1
          @stats[:active_branches] = @branches.values.count(&:active?)

          # Set as current if no current branch
          @current_branch ||= branch

          # Save branches
          save_branches

          { success: true, branch: branch }
        end
      end

      def delete_branch(name, force = false)
        @lock.synchronize do
          branch = @branches[name]
          return { success: false, error: "Branch '#{name}' not found" } unless branch

          if branch.protected? && !force
            return { success: false, error: "Branch '#{name}' is protected" }
          end

          if branch == @current_branch && !force
            return { success: false, error: "Cannot delete current branch" }
          end

          # Delete branch data
          delete_branch_data(name)

          @branches.delete(name)
          @stats[:branches_deleted] += 1
          @stats[:active_branches] = @branches.values.count(&:active?)

          save_branches

          { success: true }
        end
      end

      def checkout(name)
        @lock.synchronize do
          branch = @branches[name]
          return { success: false, error: "Branch '#{name}' not found" } unless branch

          if branch.locked?
            return { success: false, error: "Branch '#{name}' is locked" }
          end

          # Switch to branch
          @current_branch = branch

          # Update engine to branch state
          apply_branch_state(name)

          { success: true, branch: branch }
        end
      end

      def commit(change_data)
        @lock.synchronize do
          return { success: false, error: "No current branch" } unless @current_branch

          branch = @current_branch
          return { success: false, error: "Branch is locked" } if branch.locked?

          # Create commit
          commit = {
            id: generate_commit_id,
            timestamp: Time.now.iso8601,
            data: change_data,
            lsn: @engine.current_lsn
          }

          branch.commit(commit)
          @stats[:total_commits] += 1

          # Save branch state
          save_branches

          { success: true, commit: commit }
        end
      end

      def rollback(count = 1)
        @lock.synchronize do
          return { success: false, error: "No current branch" } unless @current_branch

          branch = @current_branch
          return { success: false, error: "Branch is locked" } if branch.locked?

          removed = branch.rollback(count)

          if removed&.any?
            save_branches
            { success: true, removed: removed }
          else
            { success: false, error: "Nothing to rollback" }
          end
        end
      end

      def list_branches
        @lock.synchronize do
          @branches.values.map(&:to_hash)
        end
      end

      def get_branch(name)
        @branches[name]
      end

      def current_branch_name
        @current_branch&.name
      end

      def stats
        @lock.synchronize do
          @stats.merge({
            total_branches: @branches.size,
            active_branches: @branches.values.count(&:active?),
            current_branch: @current_branch&.name,
            branch_dir: @branch_dir
          })
        end
      end

      private

      def load_branches
        branches_file = File.join(@branch_dir, "branches.json")
        return unless File.exist?(branches_file)

        begin
          data = JSON.parse(File.read(branches_file), symbolize_names: true)

          data[:branches].each do |branch_data|
            branch = Branch.new(branch_data[:name],
              id: branch_data[:id],
              parent_branch: branch_data[:parent_branch],
              base_lsn: branch_data[:base_lsn],
              description: branch_data[:description],
              owner: branch_data[:owner],
              protected: branch_data[:is_protected] || false,
              default: branch_data[:is_default] || false,
              metadata: branch_data[:metadata] || {}
            )
            branch.instance_variable_set(:@head_lsn, branch_data[:head_lsn])
            branch.instance_variable_set(:@created_at, Time.parse(branch_data[:created_at]))
            branch.instance_variable_set(:@updated_at, Time.parse(branch_data[:updated_at]))
            branch.instance_variable_set(:@state, branch_data[:state].to_sym)
            branch.instance_variable_set(:@commit_count, branch_data[:commit_count] || 0)

            @branches[branch_data[:name]] = branch
          end

          # Set current branch
          current_name = data[:current_branch]
          @current_branch = @branches[current_name] if current_name

          @stats[:branches_created] = data[:stats][:branches_created] || 0
          @stats[:total_commits] = data[:stats][:total_commits] || 0

        rescue => e
          # If loading fails, start fresh
          @branches = {}
          @current_branch = nil
        end
      end

      def save_branches
        data = {
          branches: @branches.values.map(&:to_hash),
          current_branch: @current_branch&.name,
          stats: {
            branches_created: @stats[:branches_created],
            total_commits: @stats[:total_commits]
          },
          updated_at: Time.now.iso8601
        }

        branches_file = File.join(@branch_dir, "branches.json")
        temp_file = "#{branches_file}.tmp"
        File.write(temp_file, JSON.generate(data))
        File.rename(temp_file, branches_file)
      end

      def delete_branch_data(name)
        # Delete branch data files
        branch_dir = File.join(@branch_dir, name)
        FileUtils.rm_rf(branch_dir) if Dir.exist?(branch_dir)
      end

      def apply_branch_state(name)
        # In production, would switch database to branch state
        # For now, just update current branch reference
      end

      def create_default_branch
        branch = Branch.new("main",
          default: true,
          description: "Default branch",
          protected: true
        )
        @branches["main"] = branch
        @current_branch = branch
        @stats[:branches_created] += 1
        @stats[:active_branches] = 1

        save_branches
      end

      def generate_commit_id
        "commit_#{Time.now.to_i}_#{SecureRandom.hex(8)}"
      end
    end
  end
end