# frozen_string_literal: true

require "socket"
require "time"
require "thread"
require "json"

module RubyDB
  module Replication
    # Primary - Primary database server in replication setup
    class Primary
      attr_reader :config, :engine, :replication_log, :replication_slots
      attr_reader :replicas, :stats

      def initialize(engine, config = {})
        @engine = engine
        @config = {
          host: config[:host] || "localhost",
          port: config[:port] || 7433,
          replication_port: config[:replication_port] || 7434,
          max_replicas: config[:max_replicas] || 10,
          sync_mode: config[:sync_mode] || :async,  # :async, :sync, :quorum
          sync_replicas: config[:sync_replicas] || 1,
          wal_keep_segments: config[:wal_keep_segments] || 100,
          replication_timeout: config[:replication_timeout] || 60,
          heartbeat_interval: config[:heartbeat_interval] || 10,
          enable_slots: config[:enable_slots] != false
        }

        @replication_log = ReplicationLog.new(@engine, @config)
        @replication_slots = {}
        @replicas = {}
        @replica_counter = 0
        @stats = {
          total_writes: 0,
          total_bytes_replicated: 0,
          replication_lag_ms: 0,
          sync_status: :async,
          last_commit_time: nil,
          committed_lsn: nil,
          replicated_lsn: nil,
          active_replicas: 0,
          total_replicas_connected: 0
        }
        @lock = Mutex.new
        @running = false
        @replication_server = nil
        @heartbeat_thread = nil
        @recovery = nil

        # Initialize replication slots if enabled
        initialize_slots if @config[:enable_slots]
      end

      def start
        @lock.synchronize do
          return if @running

          @running = true

          # Start replication server
          start_replication_server

          # Start heartbeat thread
          start_heartbeat

          puts "Primary replication started on port #{@config[:replication_port]}"
          true
        end
      end

      def stop
        @lock.synchronize do
          return unless @running

          @running = false

          @replication_server&.close
          @replication_server = nil

          @heartbeat_thread&.kill
          @heartbeat_thread = nil

          puts "Primary replication stopped"
          true
        end
      end

      def write(transaction_data)
        @lock.synchronize do
          # Write to WAL
          lsn = @engine.write(transaction_data)

          # Log the transaction
          @replication_log.log_transaction(transaction_data, lsn)

          # Update stats
          @stats[:total_writes] += 1
          @stats[:committed_lsn] = lsn

          # Notify replicas
          notify_replicas(transaction_data, lsn)

          # Wait for sync replicas if configured
          wait_for_sync_replicas if @config[:sync_mode] == :sync

          lsn
        end
      end

      def register_replica(replica_info)
        @lock.synchronize do
          replica_id = @replica_counter + 1
          @replica_counter = replica_id

          # Create replication slot if enabled
          slot = nil
          if @config[:enable_slots]
            slot_name = "replica_#{replica_id}"
            slot = create_replication_slot(slot_name)
          end

          replica = {
            id: replica_id,
            info: replica_info,
            connected_at: Time.now,
            last_heartbeat: Time.now,
            last_lsn: nil,
            sync_standby: false,
            slot: slot,
            connection: nil,
            lag_bytes: 0
          }

          @replicas[replica_id] = replica
          @stats[:active_replicas] = @replicas.size
          @stats[:total_replicas_connected] += 1

          replica_id
        end
      end

      def unregister_replica(replica_id)
        @lock.synchronize do
          replica = @replicas.delete(replica_id)
          return false unless replica

          # Drop replication slot
          if replica[:slot]
            drop_replication_slot(replica[:slot].name)
          end

          @stats[:active_replicas] = @replicas.size
          true
        end
      end

      def send_heartbeat(replica_id)
        @lock.synchronize do
          replica = @replicas[replica_id]
          return false unless replica

          replica[:last_heartbeat] = Time.now

          # Calculate replication lag
          if replica[:last_lsn] && @stats[:committed_lsn]
            # In production, would calculate actual byte difference
            replica[:lag_bytes] = 1024
          end

          true
        end
      end

      def get_replication_status
        @lock.synchronize do
          {
            running: @running,
            role: "primary",
            sync_mode: @config[:sync_mode],
            active_replicas: @replicas.size,
            total_writes: @stats[:total_writes],
            committed_lsn: @stats[:committed_lsn],
            replicated_lsn: @stats[:replicated_lsn],
            wal_keep_segments: @config[:wal_keep_segments],
            slots: @replication_slots.size,
            replicas: @replicas.map do |id, r|
              {
                id: id,
                connected_at: r[:connected_at].iso8601,
                last_heartbeat: r[:last_heartbeat].iso8601,
                sync_standby: r[:sync_standby],
                lag_bytes: r[:lag_bytes]
              }
            end
          }
        end
      end

      private

      def start_replication_server
        @replication_server = TCPServer.new(@config[:host], @config[:replication_port])

        Thread.new do
          while @running
            begin
              client = @replication_server.accept
              Thread.new { handle_replica_connection(client) }
            rescue => e
              # Log error but continue
            end
          end
        end
      end

      def handle_replica_connection(client)
        # In production, handle replica connection handshake
        # This would exchange authentication and replication information
        client.close
      end

      def start_heartbeat
        @heartbeat_thread = Thread.new do
          while @running
            sleep(@config[:heartbeat_interval])

            @lock.synchronize do
              @replicas.each do |id, replica|
                # Check if replica is still alive
                if Time.now - replica[:last_heartbeat] > @config[:replication_timeout]
                  unregister_replica(id)
                end
              end
            end
          end
        end
      end

      def initialize_slots
        # In production, would load existing slots from disk
      end

      def create_replication_slot(name)
        slot = ReplicationSlot.new(name, self)
        @replication_slots[name] = slot
        slot
      end

      def drop_replication_slot(name)
        @replication_slots.delete(name)
      end

      def notify_replicas(transaction_data, lsn)
        # In production, would stream to connected replicas
        @stats[:replicated_lsn] = lsn
      end

      def wait_for_sync_replicas
        # In production, would wait for sync replicas to acknowledge
        sleep(0.01)
      end
    end
  end
end