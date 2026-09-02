# frozen_string_literal: true

require "json"
require "set"
require "fileutils"
require "time"

module RubyDB
  module Storage
    # VisibilityMap - Tracks which transactions can see which rows
    # Implements MVCC visibility with proper isolation levels
    class VisibilityMap
      # Visibility states for a row version
      VISIBLE = :visible
      HIDDEN = :hidden
      DELETED = :deleted
      COMMITTED = :committed
      ABORTED = :aborted
      IN_PROGRESS = :in_progress

      attr_reader :visibility_info, :stats, :isolation_level, :active_transactions, :committed_transactions

      def initialize(page_manager, config = {})
        @page_manager = page_manager
        @visibility_info = {}
        @transaction_visibility = {}
        @snapshot_cache = {}
        @snapshot_cache_lru = []  # LRU order for cache eviction
        @max_snapshot_cache_size = config[:max_snapshot_cache] || 100
        @commit_log = []
        @abort_log = []
        @max_snapshot_age = config[:max_snapshot_age] || 3600 # 1 hour default
        @isolation_level = config[:isolation_level] || :read_committed
        @configured_visibility_path = config[:visibility_path]
        @vacuum_threshold = config[:vacuum_threshold] || 1000
        @vacuum_batch_size = config[:vacuum_batch_size] || 100
        @stats = {
          visible_checks: 0,
          hidden_checks: 0,
          snapshot_creations: 0,
          snapshot_cache_hits: 0,
          snapshot_cache_misses: 0,
          vacuum_runs: 0,
          vacuum_removed: 0,
          old_snapshots_cleared: 0,
          snapshot_evictions: 0,
          transaction_rollbacks: 0,
          row_version_chains: 0
        }
        @lock = Mutex.new
        @vacuum_lock = Mutex.new
        @active_transactions = {}
        @committed_transactions = Set.new
        @aborted_transactions = Set.new
        @row_version_chains = {}
        @version_history = Hash.new { |hash, row_id| hash[row_id] = {} }
        @next_version_id = 1
        @is_loaded = false
        
        # Create directory for visibility data
        @data_dir = config[:data_dir] || "."
        FileUtils.mkdir_p(@data_dir) unless Dir.exist?(@data_dir)
        
        load_visibility
        start_vacuum_thread if config[:auto_vacuum] != false
      end

      # Mark a row as visible to a specific transaction
      def mark_visible(row_id, transaction_id, commit_id = nil)
        @lock.synchronize do
          @stats[:visible_checks] += 1
          
          version_id = @next_version_id
          @next_version_id += 1
          
          existing = @visibility_info[row_id]
          prev_version = existing ? existing[:version] : 0
          prev_chain = existing ? @row_version_chains[row_id] : nil
          
          @visibility_info[row_id] = {
            state: VISIBLE,
            visible_to: transaction_id,
            commit_id: commit_id || (transaction_id.to_i == 0 ? 0 : nil),
            created_at: Time.now,
            last_modified: Time.now,
            version: version_id,
            prev_version: prev_version,
            row_id: row_id,
            deleted: false
          }
          remember_version(row_id, @visibility_info[row_id])
          
          # Track version chain
          @row_version_chains[row_id] ||= []
          @row_version_chains[row_id] << version_id
          
          if @row_version_chains[row_id].size > 100
            # Trim old version chains to prevent unbounded growth
            @row_version_chains[row_id] = @row_version_chains[row_id].last(50)
          end
          
          true
        end
      end

      # Mark a row as hidden from a specific transaction (deleted or updated)
      def mark_hidden(row_id, transaction_id, commit_id = nil)
        @lock.synchronize do
          @stats[:hidden_checks] += 1
          
          version_id = @next_version_id
          @next_version_id += 1
          
          existing = @visibility_info[row_id]
          prev_version = existing ? existing[:version] : 0
          
          @visibility_info[row_id] = {
            state: HIDDEN,
            hidden_from: transaction_id,
            commit_id: commit_id || (transaction_id.to_i == 0 ? 0 : nil),
            created_at: Time.now,
            last_modified: Time.now,
            version: version_id,
            prev_version: prev_version,
            row_id: row_id,
            deleted: false
          }
          remember_version(row_id, @visibility_info[row_id])
          
          @row_version_chains[row_id] ||= []
          @row_version_chains[row_id] << version_id
          
          true
        end
      end

      # Mark a row as deleted (final state)
      def mark_deleted(row_id, transaction_id, commit_id = nil)
        @lock.synchronize do
          version_id = @next_version_id
          @next_version_id += 1
          
          existing = @visibility_info[row_id]
          prev_version = existing ? existing[:version] : 0
          
          @visibility_info[row_id] = {
            state: DELETED,
            deleted_by: transaction_id,
            commit_id: commit_id || (transaction_id.to_i == 0 ? 0 : nil),
            created_at: Time.now,
            last_modified: Time.now,
            version: version_id,
            prev_version: prev_version,
            row_id: row_id,
            deleted: true
          }
          remember_version(row_id, @visibility_info[row_id])
          
          @row_version_chains[row_id] ||= []
          @row_version_chains[row_id] << version_id
          
          true
        end
      end

      # Check if a row is visible to a transaction
      def is_visible?(row_id, transaction_id, snapshot_id = nil)
        @lock.synchronize do
          @stats[:visible_checks] += 1
          
          info = @visibility_info[row_id]
          
          # Rows created before visibility tracking was introduced remain
          # visible; newly written rows always receive visibility metadata.
          return true if info.nil?
          
          # Check if row is deleted
          return false if info[:state] == DELETED && info[:deleted_by] != transaction_id
          
          # Check if there's a snapshot for this transaction
          if snapshot_id && @snapshot_cache.key?(snapshot_id)
            @stats[:snapshot_cache_hits] += 1
            snapshot = @snapshot_cache[snapshot_id]
            update_lru(snapshot_id)
            return snapshot_visibility_check(info, snapshot, transaction_id)
          end
          
          # Check state-based visibility
          case info[:state]
          when VISIBLE, COMMITTED
            # Check if visible_to is set
            if info[:visible_to]
              # Row is visible to this transaction if:
              # 1. Transaction_id matches the visible_to
              # 2. Or transaction_id is after commit_id (committed)
              # 3. Or transaction is active and owns the visibility
              if info[:visible_to] == transaction_id
                return true
              end
              
              if info[:commit_id]
                return true if info[:commit_id].to_i == 0
                return true if @committed_transactions.include?(info[:commit_id])
              end
              
              return false
            end
            true
            
          when HIDDEN
            # Row is hidden from this transaction if:
            # 1. hidden_from matches transaction_id (same transaction hid it)
            # 2. Or commit_id > transaction_id (committed after transaction started)
            # 3. Or transaction is the one that hid it
            if info[:hidden_from]
              return false if info[:hidden_from] == transaction_id
              
              if info[:commit_id] && info[:commit_id] > transaction_id
                return false
              end
            end
            true
            
          when DELETED
            # Deleted rows are not visible to anyone except the transaction that deleted them
            return info[:deleted_by] == transaction_id if info[:deleted_by]
            false
            
          else
            true
          end
        end
      end

      # Check visibility using a snapshot
      def snapshot_visibility_check(info, snapshot, transaction_id)
        snapshot_start = snapshot[:start_time]
        snapshot_active = snapshot[:active_transactions]
        snapshot_committed = snapshot[:committed_transactions] || []
        
        # If row was created after snapshot, it's not visible
        if info[:created_at] > snapshot_start
          return false
        end
        
        # If row was modified after snapshot, check if it's visible
        if info[:last_modified] > snapshot_start
          # Check if the modifying transaction is in the snapshot's active list
          if info[:commit_id]
            # If commit_id is in active transactions when snapshot was taken, it's not visible
            return false if snapshot_active.include?(info[:commit_id])
            
            # If commit_id was committed after snapshot, it's not visible
            return false if snapshot_committed.include?(info[:commit_id])
            
            # If commit_id is the current transaction, it might be visible
            return true if info[:commit_id] == transaction_id
          end
          
          # Check if this is the current transaction's own changes
          if info[:visible_to] == transaction_id || info[:hidden_from] == transaction_id
            return true
          end
          
          return false
        end
        
        # Row was created before snapshot and not modified after
        true
      end

      # Create a snapshot for a transaction
      def create_snapshot(transaction_id)
        @lock.synchronize do
          @stats[:snapshot_creations] += 1
          
          snapshot_id = "snapshot_#{transaction_id}_#{Time.now.to_i}_#{@stats[:snapshot_creations]}"
          
          snapshot = {
            id: snapshot_id,
            transaction_id: transaction_id,
            start_time: Time.now,
            active_transactions: @active_transactions.keys.dup,
            committed_transactions: @committed_transactions.to_a.dup,
            isolation_level: @isolation_level,
            created_at: Time.now,
            last_access: Time.now
          }
          
          # Store snapshot with LRU management
          if @snapshot_cache.size >= @max_snapshot_cache_size
            evict_oldest_snapshot
          end
          
          @snapshot_cache[snapshot_id] = snapshot
          @snapshot_cache_lru.unshift(snapshot_id)
          
          # Clean old snapshots
          clean_old_snapshots
          
          snapshot_id
        end
      end

      # Get a snapshot by ID
      def get_snapshot(snapshot_id)
        @lock.synchronize do
          snapshot = @snapshot_cache[snapshot_id]
          update_lru(snapshot_id) if snapshot
          snapshot
        end
      end

      # Register an active transaction
      def register_transaction(transaction_id)
        @lock.synchronize do
          @active_transactions[transaction_id] = {
            started_at: Time.now,
            status: :active,
            visibility: {},
            row_locks: Set.new,
            snapshot_id: nil
          }
          
          # Stronger isolation levels are rejected by Engine until historical
          # row versions are persisted. Do not create a snapshot here while
          # holding @lock; create_snapshot also takes this lock.
          
          true
        end
      end

      # Commit a transaction
      def commit_transaction(transaction_id, commit_id = nil)
        @lock.synchronize do
          commit_id ||= transaction_id
          
          # Get transaction's snapshot
          tx_info = @active_transactions[transaction_id]
          snapshot_id = tx_info ? tx_info[:snapshot_id] : nil
          
          # Update all visibility info committed by this transaction
          updated_rows = []
          
          @visibility_info.each do |row_id, info|
            if info[:visible_to] == transaction_id || 
               info[:hidden_from] == transaction_id ||
               info[:deleted_by] == transaction_id
              
              # Mark as committed
              info[:commit_id] = commit_id
              info[:state] = COMMITTED if info[:state] == VISIBLE || info[:state] == HIDDEN
              info[:last_modified] = Time.now
              updated_rows << row_id
              
              # Update version chain
              if @row_version_chains[row_id]
                @row_version_chains[row_id] << info[:version]
              end
            end
          end
          
          # Move to committed transactions
          @committed_transactions.add(transaction_id)
          @active_transactions.delete(transaction_id)
          
          @commit_log << { 
            transaction_id: transaction_id, 
            commit_id: commit_id, 
            time: Time.now,
            rows_updated: updated_rows.size,
            snapshot_id: snapshot_id
          }
          
          # Clean commit log if too large
          if @commit_log.size > 1000
            @commit_log = @commit_log.last(500)
          end
          
          # Remove transaction's snapshot
          if snapshot_id
            @snapshot_cache.delete(snapshot_id)
            @snapshot_cache_lru.delete(snapshot_id)
          end
          
          # Return commit info
          {
            transaction_id: transaction_id,
            commit_id: commit_id,
            rows_updated: updated_rows.size,
            committed_at: Time.now
          }
        end
      end

      # Abort a transaction
      def abort_transaction(transaction_id)
        @lock.synchronize do
          @stats[:transaction_rollbacks] += 1
          
          # Get transaction's snapshot
          tx_info = @active_transactions[transaction_id]
          snapshot_id = tx_info ? tx_info[:snapshot_id] : nil
          
          # Track which rows were affected
          affected_rows = []
          
          # Revert visibility changes made by this transaction
          @visibility_info.each do |row_id, info|
            if info[:visible_to] == transaction_id || 
               info[:hidden_from] == transaction_id ||
               info[:deleted_by] == transaction_id
              
              affected_rows << row_id
              
              # Revert to previous version if exists
              prev_version = info[:prev_version]
              
              if prev_version > 0
                # Find previous version in version chain
                if @row_version_chains[row_id]
                  prev_info = find_version_by_id(row_id, prev_version)
                  if prev_info
                    # Restore previous state
                    @visibility_info[row_id] = prev_info
                  else
                    # Remove completely if previous version not found
                    @visibility_info.delete(row_id)
                  end
                end
              else
                # No previous version - remove completely
                @visibility_info.delete(row_id)
              end
            end
          end
          
          # Move to aborted transactions
          @aborted_transactions.add(transaction_id)
          @active_transactions.delete(transaction_id)
          
          @abort_log << { 
            transaction_id: transaction_id, 
            time: Time.now,
            rows_affected: affected_rows.size,
            snapshot_id: snapshot_id
          }
          
          # Clean abort log if too large
          if @abort_log.size > 1000
            @abort_log = @abort_log.last(500)
          end
          
          # Remove transaction's snapshot
          if snapshot_id
            @snapshot_cache.delete(snapshot_id)
            @snapshot_cache_lru.delete(snapshot_id)
          end
          
          affected_rows.size
        end
      end

      # Find a version by ID in the version chain
      def find_version_by_id(row_id, version_id)
        history = @version_history[row_id]
        history[version_id.to_i] || begin
          info = @visibility_info[row_id]
          info if info && info[:version].to_i == version_id.to_i
        end
      end

      # Check if a transaction is active
      def transaction_active?(transaction_id)
        @active_transactions.key?(transaction_id)
      end

      # Check if a transaction is committed
      def transaction_committed?(transaction_id)
        @committed_transactions.include?(transaction_id)
      end

      # Check if a transaction is aborted
      def transaction_aborted?(transaction_id)
        @aborted_transactions.include?(transaction_id)
      end

      # Get all rows visible to a transaction
      def transaction_visible_rows(transaction_id)
        @lock.synchronize do
          result = []
          @visibility_info.each do |row_id, info|
            if is_visible?(row_id, transaction_id)
              result << row_id
            end
          end
          result
        end
      end

      # Get all rows hidden from a transaction
      def transaction_hidden_rows(transaction_id)
        @lock.synchronize do
          result = []
          @visibility_info.each do |row_id, info|
            unless is_visible?(row_id, transaction_id)
              result << row_id
            end
          end
          result
        end
      end

      # Get row visibility history
      def row_history(row_id)
        @lock.synchronize do
          info = @visibility_info[row_id]
          return [] unless info
          
          history = [info.dup]
          
          # Follow version chain backwards
          current = info
          while current && current[:prev_version] > 0
            prev_info = find_version_by_id(row_id, current[:prev_version])
            if prev_info
              history << prev_info.dup
              current = prev_info
            else
              break
            end
          end
          
          history.reverse
        end
      end

      # Get row version history
      def row_versions(row_id)
        @lock.synchronize do
          info = @visibility_info[row_id]
          return [] unless info
          
          versions = []
          current = info
          
          while current
            versions << {
              version: current[:version],
              state: current[:state],
              transaction_id: current[:visible_to] || current[:hidden_from] || current[:deleted_by],
              created_at: current[:created_at],
              commit_id: current[:commit_id]
            }
            
            break if current[:prev_version] == 0
            
            current = find_version_by_id(row_id, current[:prev_version])
          end
          
          versions
        end
      end

      # Vacuum old/deleted rows
      def vacuum(max_age = @vacuum_threshold, batch_size = @vacuum_batch_size)
        @vacuum_lock.synchronize do
          @stats[:vacuum_runs] += 1
          
          removed = 0
          now = Time.now
          rows_to_remove = []
          
          # Collect rows to vacuum
          @visibility_info.each do |row_id, info|
            should_remove = false
            
            case info[:state]
            when DELETED
              age = now - info[:last_modified]
              should_remove = age > max_age && !needed_for_rollback?(row_id)
              
            when COMMITTED
              # Check if all transactions that need this version are gone
              should_remove = committed_version_expired?(info)
              
            when ABORTED
              should_remove = true
            end
            
            if should_remove
              rows_to_remove << row_id
              removed += 1
            end
            
            break if removed >= batch_size
          end
          
          # Remove rows
          rows_to_remove.each do |row_id|
            @visibility_info.delete(row_id)
            @row_version_chains.delete(row_id)
            remove_row_from_disk(row_id)
          end
          
          @stats[:vacuum_removed] += removed
          
          # Clean up old snapshots and transactions
          clean_old_snapshots
          clean_old_transactions
          
          # Flush if we removed a significant number of rows
          if removed > 0
            flush
          end
          
          {
            removed: removed,
            total_rows: @visibility_info.size,
            total_vacuumed: @stats[:vacuum_removed]
          }
        end
      end

      # Check if a deleted row is needed for potential rollback
      def needed_for_rollback?(row_id)
        # Check if any active transaction might need to rollback this row
        @active_transactions.each do |tx_id, _info|
          # If a transaction modified this row, it might need to rollback
          if @visibility_info[row_id] && 
             (@visibility_info[row_id][:visible_to] == tx_id ||
              @visibility_info[row_id][:hidden_from] == tx_id ||
              @visibility_info[row_id][:deleted_by] == tx_id)
            return true
          end
        end
        false
      end

      # Check if a committed version has expired
      def committed_version_expired?(info)
        return true if @active_transactions.empty?
        
        # If no active transactions need this version
        min_active = @active_transactions.keys.min || 0
        info[:commit_id] && info[:commit_id] < min_active
      end

      # Load visibility map from disk
      def load_visibility
        @lock.synchronize do
          @visibility_info.clear
          @active_transactions.clear
          @committed_transactions.clear
          @aborted_transactions.clear
          @snapshot_cache.clear
          @snapshot_cache_lru.clear
          @row_version_chains.clear
          @version_history.clear
          
          # Try to load from storage
          begin
            if File.exist?(visibility_path)
              data = File.read(visibility_path)
              parsed = JSON.parse(data, symbolize_names: true)
              
              if parsed[:visibility_info]
                parsed[:visibility_info].each do |row_id_str, info|
                  row_id = row_id_str.to_s.to_i
                  symbolized_info = {}
                  info.each do |key, value|
                    value = value.to_sym if %i[state].include?(key.to_sym) && value.respond_to?(:to_sym)
                    symbolized_info[key.to_sym] = value
                  end
                  @visibility_info[row_id] = symbolized_info
                  remember_version(row_id, symbolized_info)
                end
              end

              if parsed[:version_history]
                parsed[:version_history].each do |row_id_str, versions|
                  versions.each do |version_id, info|
                    normalized = normalize_loaded_info(info)
                    @version_history[row_id_str.to_s.to_i][version_id.to_s.to_i] = normalized
                  end
                end
              end
              
              @active_transactions = parsed[:active_transactions] || {}
              @committed_transactions = Set.new(parsed[:committed_transactions] || [])
              @aborted_transactions = Set.new(parsed[:aborted_transactions] || [])
              @next_version_id = parsed[:next_version_id] || 1
              @row_version_chains = parsed[:row_version_chains] || {}
              
              # Clean up any invalid data
              @active_transactions.each do |tx_id, info|
                if info[:started_at]
                  info[:started_at] = Time.parse(info[:started_at]) if info[:started_at].is_a?(String)
                end
              end
              
              @is_loaded = true
            end
          rescue => e
            # Never discard persisted visibility state silently; a corrupt or
            # incompatible MVCC map must fail closed so recovery can intervene.
            raise RubyDB::CorruptionError, "Failed to load visibility map: #{e.message}"
          end
        end
      end

      # Flush visibility map to disk
      def flush
        @lock.synchronize do
          begin
            data = {
              visibility_info: @visibility_info,
              active_transactions: @active_transactions,
              committed_transactions: @committed_transactions.to_a,
              aborted_transactions: @aborted_transactions.to_a,
              next_version_id: @next_version_id,
              row_version_chains: @row_version_chains,
              version_history: @version_history,
              timestamp: Time.now.iso8601,
              version: 2
            }
            
            # Write to a temp file first, then rename
            temp_path = "#{visibility_path}.tmp"
            File.write(temp_path, JSON.generate(data))
            FileUtils.mv(temp_path, visibility_path)
            
            true
          rescue => e
            false
          end
        end
      end

      # Remove a row from disk storage
      def remove_row_from_disk(row_id)
        true
      end

      def remember_version(row_id, info)
        @version_history[row_id][info[:version].to_i] = info.dup
      end

      def normalize_loaded_info(info)
        info.each_with_object({}) do |(key, value), normalized|
          normalized[key.to_sym] = if key.to_sym == :state && value.respond_to?(:to_sym)
            value.to_sym
          elsif %i[created_at last_modified].include?(key.to_sym) && value.is_a?(String)
            Time.parse(value)
          else
            value
          end
        end
      end

      # Get visibility statistics
      def stats
        @lock.synchronize do
          # Calculate average version chain length
          avg_chain = if @row_version_chains.empty?
            0.0
          else
            @row_version_chains.values.map(&:size).sum.to_f / @row_version_chains.size
          end
          
          {
            total_rows: @visibility_info.size,
            visible_rows: @visibility_info.count { |_, info| info[:state] == VISIBLE || info[:state] == COMMITTED },
            hidden_rows: @visibility_info.count { |_, info| info[:state] == HIDDEN },
            deleted_rows: @visibility_info.count { |_, info| info[:state] == DELETED },
            active_transactions: @active_transactions.size,
            committed_transactions: @committed_transactions.size,
            aborted_transactions: @aborted_transactions.size,
            snapshots: @snapshot_cache.size,
            version_chains: @row_version_chains.size,
            avg_chain_length: avg_chain.round(2),
            visible_checks: @stats[:visible_checks],
            hidden_checks: @stats[:hidden_checks],
            snapshot_creations: @stats[:snapshot_creations],
            snapshot_cache_hits: @stats[:snapshot_cache_hits],
            snapshot_cache_misses: @stats[:snapshot_cache_misses],
            snapshot_cache_hit_rate: snapshot_hit_rate,
            vacuum_runs: @stats[:vacuum_runs],
            vacuum_removed: @stats[:vacuum_removed],
            old_snapshots_cleared: @stats[:old_snapshots_cleared],
            snapshot_evictions: @stats[:snapshot_evictions],
            transaction_rollbacks: @stats[:transaction_rollbacks],
            isolation_level: @isolation_level,
            next_version_id: @next_version_id,
            is_loaded: @is_loaded
          }
        end
      end

      # Clean up old snapshots
      def clean_old_snapshots
        @lock.synchronize do
          now = Time.now
          to_remove = []
          
          @snapshot_cache.each do |id, snapshot|
            age = now - snapshot[:created_at]
            if age > @max_snapshot_age
              to_remove << id
            end
          end
          
          to_remove.each do |id|
            @snapshot_cache.delete(id)
            @snapshot_cache_lru.delete(id)
            @stats[:old_snapshots_cleared] += 1
          end
        end
      end

      # Clean up old transaction records
      def clean_old_transactions
        @lock.synchronize do
          now = Time.now
          cutoff = now - 86400 # 24 hours
          
          @active_transactions.each do |tx_id, info|
            if info[:started_at] < cutoff
              @active_transactions.delete(tx_id)
            end
          end
          
          # Clean up old committed transactions
          old_committed = @committed_transactions.to_a.select do |tx_id|
            # Check if transaction is older than cutoff
            # For simplicity, we'll just keep recent ones
            false
          end
          
          # Keep committed transactions that might still be needed
          @committed_transactions = Set.new(@committed_transactions.to_a.last(1000))
        end
      end

      # Start vacuum thread for automatic cleanup
      def start_vacuum_thread
        Thread.new do
          loop do
            sleep(300) # Run every 5 minutes
            begin
              vacuum
            rescue => e
              # Log error but continue
              puts "Vacuum error: #{e.message}" if $DEBUG
            end
          end
        end
      end

      # Set isolation level
      def isolation_level=(level)
        @lock.synchronize do
          @isolation_level = level
        end
      end

      # Get row visibility info
      def get_visibility_info(row_id)
        @lock.synchronize do
          @visibility_info[row_id]
        end
      end

      # Check if a row exists
      def row_exists?(row_id)
        @lock.synchronize do
          @visibility_info.key?(row_id)
        end
      end

      # Get active transaction count
      def active_transaction_count
        @lock.synchronize do
          @active_transactions.size
        end
      end

      # Get committed transaction count
      def committed_transaction_count
        @lock.synchronize do
          @committed_transactions.size
        end
      end

      # Reset the visibility map (dangerous - for testing)
      def reset!
        @lock.synchronize do
          @visibility_info.clear
          @active_transactions.clear
          @committed_transactions.clear
          @aborted_transactions.clear
          @snapshot_cache.clear
          @snapshot_cache_lru.clear
          @commit_log.clear
          @abort_log.clear
          @row_version_chains.clear
          @next_version_id = 1
          @stats = {
            visible_checks: 0,
            hidden_checks: 0,
            snapshot_creations: 0,
            snapshot_cache_hits: 0,
            snapshot_cache_misses: 0,
            vacuum_runs: 0,
            vacuum_removed: 0,
            old_snapshots_cleared: 0,
            snapshot_evictions: 0,
            transaction_rollbacks: 0,
            row_version_chains: 0
          }
          File.delete(visibility_path) if File.exist?(visibility_path)
          true
        end
      end

      # to_s implementation
      def to_s
        "VisibilityMap: #{@visibility_info.size} entries, #{@active_transactions.size} active transactions, #{@snapshot_cache.size} snapshots"
      end

      private

      # Update LRU order for a snapshot
      def update_lru(snapshot_id)
        @snapshot_cache_lru.delete(snapshot_id)
        @snapshot_cache_lru.unshift(snapshot_id)
      end

      # Evict the oldest snapshot from cache
      def evict_oldest_snapshot
        if @snapshot_cache_lru.any?
          oldest_id = @snapshot_cache_lru.last
          @snapshot_cache.delete(oldest_id)
          @snapshot_cache_lru.pop
          @stats[:snapshot_evictions] += 1
          true
        else
          false
        end
      end

      # Calculate snapshot hit rate
      def snapshot_hit_rate
        total = @stats[:snapshot_cache_hits] + @stats[:snapshot_cache_misses]
        return 0.0 if total == 0
        (@stats[:snapshot_cache_hits].to_f / total * 100).round(2)
      end

      # Path for visibility data file
      def visibility_path
        @visibility_path ||= begin
          if @configured_visibility_path
            FileUtils.mkdir_p(File.dirname(@configured_visibility_path))
            @configured_visibility_path
          elsif @page_manager && @page_manager.respond_to?(:path)
            base_path = @page_manager.path
            if base_path
              File.join(@data_dir, "#{File.basename(base_path)}.visibility")
            else
              File.join(@data_dir, "visibility_map.json")
            end
          else
            File.join(@data_dir, "visibility_map.json")
          end
        end
      end

      # Check if a commit exists in the log
      def commit_exists?(commit_id)
        @commit_log.any? { |log| log[:commit_id] == commit_id }
      end
    end
  end
end
