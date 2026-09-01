# frozen_string_literal: true

require "fileutils"
require "time"
require "json"

module RubyDB
  module Backup
    # Incremental - Handles incremental backups
    class Incremental
      attr_reader :stats

      def initialize(engine, config = {})
        @engine = engine
        @config = config
        @incremental_dir = config[:incremental_dir] || "incremental"
        @backup_dir = config[:backup_dir] || "backups"
        @max_incrementals = config[:max_incrementals] || 10
        @stats = {
          incrementals_created: 0,
          incrementals_restored: 0,
          total_size_bytes: 0,
          last_incremental: nil,
          chain_length: 0
        }
        @lock = Mutex.new
        @incrementals = {}
        @chains = {}

        FileUtils.mkdir_p(@incremental_dir)
        load_incrementals
      end

      def create_incremental(base_backup = nil)
        @lock.synchronize do
          start_time = Time.now

          # Find base backup if not specified
          base_backup ||= find_latest_backup
          unless base_backup
            return { success: false, error: "No base backup found" }
          end

          # Get last LSN from base backup or previous incremental
          last_lsn = get_last_lsn(base_backup)

          # Create incremental backup
          incremental_name = "inc_#{Time.now.strftime('%Y%m%d_%H%M%S')}"
          incremental_path = File.join(@incremental_dir, incremental_name)
          FileUtils.mkdir_p(incremental_path)

          # Capture changes since last backup
          changes = capture_changes_since(last_lsn)

          # Write changes
          changes_path = File.join(incremental_path, "changes.json")
          File.write(changes_path, JSON.generate(changes))

          # Write metadata
          metadata = {
            name: incremental_name,
            base_backup: base_backup,
            created_at: Time.now.iso8601,
            last_lsn: last_lsn,
            new_lsn: changes[:new_lsn],
            change_count: changes[:changes].size,
            size: calculate_size(incremental_path)
          }

          metadata_path = File.join(incremental_path, "metadata.json")
          File.write(metadata_path, JSON.generate(metadata))

          # Update chain
          @chains[base_backup] ||= []
          @chains[base_backup] << metadata
          @incrementals[incremental_name] = metadata

          # Update stats
          @stats[:incrementals_created] += 1
          @stats[:total_size_bytes] += metadata[:size]
          @stats[:last_incremental] = Time.now
          @stats[:chain_length] = @chains[base_backup].size

          # Clean old incrementals
          clean_old_incrementals

          {
            success: true,
            incremental_name: incremental_name,
            metadata: metadata,
            elapsed_ms: (Time.now - start_time) * 1000
          }
        end
      end

      def restore_to_lsn(target_lsn, options = {})
        @lock.synchronize do
          start_time = Time.now

          # Find the chain that covers the target LSN
          chain = find_chain_for_lsn(target_lsn)
          unless chain
            return { success: false, error: "No chain found for LSN" }
          end

          # Restore base backup
          base_backup = chain[:base]
          restore_base = restore_backup(base_backup)

          unless restore_base[:success]
            return { success: false, error: "Failed to restore base backup" }
          end

          # Apply incrementals in order
          applied = []
          chain[:incrementals].each do |inc|
            break if inc[:new_lsn] > target_lsn

            apply_incremental(inc)
            applied << inc[:name]
          end

          @stats[:incrementals_restored] += 1

          {
            success: true,
            restored_to_lsn: target_lsn,
            applied_incrementals: applied,
            count: applied.size,
            elapsed_ms: (Time.now - start_time) * 1000
          }
        end
      end

      def restore_to_time(target_time, options = {})
        @lock.synchronize do
          # Find incremental closest to target time
          target = Time.parse(target_time)
          best = nil
          best_diff = Float::INFINITY

          @incrementals.each do |name, inc|
            diff = (Time.parse(inc[:created_at]) - target).abs
            if diff < best_diff
              best_diff = diff
              best = inc
            end
          end

          unless best
            return { success: false, error: "No incremental found for time" }
          end

          restore_to_lsn(best[:new_lsn], options)
        end
      end

      def list_incrementals
        @lock.synchronize do
          @incrementals.values.sort_by { |i| i[:created_at] }.reverse
        end
      end

      def list_chains
        @lock.synchronize do
          @chains.transform_values { |chain| chain.map { |c| c[:name] } }
        end
      end

      def delete_incremental(incremental_name)
        @lock.synchronize do
          inc = @incrementals[incremental_name]
          return { success: false, error: "Incremental not found" } unless inc

          path = File.join(@incremental_dir, incremental_name)
          size = calculate_size(path)
          FileUtils.rm_rf(path)

          @incrementals.delete(incremental_name)
          @stats[:total_size_bytes] -= size

          { success: true }
        end
      end

      def stats
        @lock.synchronize do
          @stats.merge({
            incrementals: @incrementals.size,
            chains: @chains.size,
            incremental_dir: @incremental_dir,
            max_incrementals: @max_incrementals
          })
        end
      end

      private

      def load_incrementals
        Dir.glob(File.join(@incremental_dir, "inc_*")).each do |path|
          metadata_path = File.join(path, "metadata.json")
          next unless File.exist?(metadata_path)

          begin
            metadata = JSON.parse(File.read(metadata_path), symbolize_names: true)
            @incrementals[metadata[:name]] = metadata

            base = metadata[:base_backup]
            @chains[base] ||= []
            @chains[base] << metadata
          rescue
            # Skip corrupted incrementals
          end
        end

        # Sort chains by time
        @chains.each do |base, chain|
          @chains[base] = chain.sort_by { |c| c[:created_at] }
        end
      end

      def find_latest_backup
        backups = list_available_backups
        backups.first
      end

      def find_chain_for_lsn(target_lsn)
        @chains.each do |base, chain|
          last = chain.last
          if last && last[:new_lsn] >= target_lsn
            return { base: base, incrementals: chain }
          end
        end
        nil
      end

      def get_last_lsn(backup)
        # In production, would get LSN from backup metadata
        backup_path = File.join(@backup_dir, backup)
        manifest_path = File.join(backup_path, "manifest.json")
        return 0 unless File.exist?(manifest_path)

        manifest = JSON.parse(File.read(manifest_path), symbolize_names: true)
        manifest[:lsn] || 0
      end

      def capture_changes_since(last_lsn)
        # In production, would capture changes from WAL
        {
          new_lsn: last_lsn + 1000,
          changes: [
            { type: "insert", table: "users", data: { id: 1, name: "John" } }
          ]
        }
      end

      def calculate_size(path)
        Dir.glob(File.join(path, "**/*")).sum do |f|
          File.size(f) if File.file?(f)
        end || 0
      end

      def restore_backup(backup_name)
        backup_path = File.join(@backup_dir, backup_name)
        restore = Restore.new(@engine, @config)
        restore.restore(backup_path)
      end

      def apply_incremental(inc)
        # In production, would apply incremental changes
        inc_path = File.join(@incremental_dir, inc[:name])
        changes_path = File.join(inc_path, "changes.json")
        return unless File.exist?(changes_path)

        changes = JSON.parse(File.read(changes_path), symbolize_names: true)
        changes[:changes].each do |change|
          case change[:type]
          when "insert"
            @engine.insert_row(change[:table], change[:columns], change[:data])
          when "update"
            @engine.update_row(change[:table], change[:row_id], change[:data])
          when "delete"
            @engine.delete_row(change[:table], change[:row_id])
          end
        end
      end

      def list_available_backups
        backup = Backup.new(@engine, @config)
        backups = backup.list_backups
        backups.map { |b| b[:name] }
      end

      def clean_old_incrementals
        @chains.each do |base, chain|
          if chain.size > @max_incrementals
            to_remove = chain.first(chain.size - @max_incrementals)
            to_remove.each do |inc|
              delete_incremental(inc[:name])
            end
          end
        end
      end
    end
  end
end