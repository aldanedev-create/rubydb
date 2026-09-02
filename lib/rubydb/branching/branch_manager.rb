# frozen_string_literal: true

require "fileutils"
require "json"
require "time"

module RubyDB
  module Branching
    class BranchingError < StandardError; end unless const_defined?(:BranchingError)

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
          return { success: false, error: "Invalid branch name" } unless valid_branch_name?(name)

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
          branch.instance_variable_set(:@state_snapshot, @engine.export_state) if @engine.respond_to?(:export_state)

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
          return { success: false, error: "Invalid branch name" } unless valid_branch_name?(name)

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

          unless @engine.respond_to?(:apply_branch_state)
            return { success: false, error: "Branch checkout requires an engine state-application hook" }
          end

          # Apply the persisted state before publishing the branch switch. If
          # state application fails, the manager and engine must continue to
          # agree about the active branch.
          applied = apply_branch_state(name)
          return { success: false, error: "Unable to apply branch state" } if applied == false

          @current_branch = branch

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
            lsn: (@engine.current_lsn if @engine.respond_to?(:current_lsn))
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

      # Persist branch metadata after an external operation (such as merge)
      # has changed a branch object through the public branching API.
      def persist!
        @lock.synchronize { save_branches }
        true
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

      def valid_branch_name?(name)
        value = name.to_s
        !value.empty? && value == File.basename(value) && !value.include?(File::SEPARATOR) &&
          (File::ALT_SEPARATOR.nil? || !value.include?(File::ALT_SEPARATOR))
      end

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
              metadata: branch_data[:metadata] || {},
              state_snapshot: branch_data[:state_snapshot]
            )
            branch.instance_variable_set(:@head_lsn, branch_data[:head_lsn])
            branch.instance_variable_set(:@created_at, Time.parse(branch_data[:created_at]))
            branch.instance_variable_set(:@updated_at, Time.parse(branch_data[:updated_at]))
            branch.instance_variable_set(:@state, branch_data[:state].to_sym)
            branch.instance_variable_set(:@commit_count, branch_data[:commit_count] || 0)
            branch.instance_variable_set(:@changes, branch_data[:changes] || [])

            @branches[branch_data[:name]] = branch
          end

          # Set current branch
          current_name = data[:current_branch]
          @current_branch = @branches[current_name] if current_name

          @stats[:branches_created] = data[:stats][:branches_created] || 0
          @stats[:total_commits] = data[:stats][:total_commits] || 0

        rescue StandardError => error
          raise BranchingError, "Invalid branch catalog #{branches_file}: #{error.message}"
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
        branch = @branches.fetch(name)
        return false unless @engine.respond_to?(:apply_branch_state)

        snapshot = branch.respond_to?(:state_snapshot) ? branch.state_snapshot : nil
        changes = branch.respond_to?(:logical_changes) ? branch.logical_changes : branch.changes
        @engine.apply_branch_state(base: snapshot, changes: changes)
      end

      def create_default_branch
        branch = Branch.new("main",
          default: true,
          description: "Default branch",
          protected: true,
          state_snapshot: (@engine.export_state if @engine.respond_to?(:export_state))
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
