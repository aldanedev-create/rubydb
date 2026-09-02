# frozen_string_literal: true

require "socket"
require "time"
require "thread"
require "json"
require "monitor"
require "fileutils"
require_relative "replication_slot"
require_relative "fencing"

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
          enable_slots: config[:enable_slots] != false,
          fence_path: config[:fence_path] || "#{@engine.path}.fence",
          node_id: config[:node_id] || "primary_#{Process.pid}"
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
        @lock = Monitor.new
        @slot_path = config[:slot_path] || "#{@engine.path}.replication_slots.json"
        @running = false
        @replication_server = nil
        @heartbeat_thread = nil
        @recovery = nil
        @fencing_lease = FencingLease.new(@config[:fence_path], @config[:node_id]).acquire!

        # Initialize replication slots if enabled
        initialize_slots if @config[:enable_slots]
      end

      def start
        @lock.synchronize do
          return if @running

          @fencing_lease.assert_valid!

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
          @fencing_lease.assert_valid!
          # Logical replication uses a monotonic LSN over durable envelopes.
          lsn = (@replication_log.get_last_lsn || 0) + 1

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

      def fencing_status
        @lock.synchronize do
          { node_id: @fencing_lease.node_id, epoch: @fencing_lease.epoch, valid: @fencing_lease.valid? }
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
            last_ack_lsn: nil,
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
            replica[:lag_bytes] = [@stats[:committed_lsn].to_i - replica[:last_lsn].to_i, 0].max
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
                lag_bytes: r[:lag_bytes],
                acknowledged_lsn: r[:last_ack_lsn]
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
        line = client.gets
        handshake = JSON.parse(line, symbolize_names: true)
        unless handshake[:type].to_s == "replica_handshake"
          client.write(JSON.generate(success: false, error: "Invalid replication handshake") + "\n")
          return
        end

        replica_id = register_replica(handshake)
        @lock.synchronize { @replicas[replica_id][:connection] = client }
        client.write(JSON.generate(success: true, replica_id: replica_id, mode: "logical") + "\n")
        client.flush

        from_lsn = handshake[:wal_position].to_i + 1
        @replication_log.read_transactions(from_lsn).each do |entry|
          send_replication_entry(client, entry)
          @lock.synchronize { @replicas[replica_id][:last_lsn] = entry[:lsn] if @replicas[replica_id] }
        end

        while @running && !client.closed?
          ready = IO.select([client], nil, nil, 0.1)
          next unless ready
          line = client.gets
          break unless line
          message = JSON.parse(line, symbolize_names: true)
          next unless message[:type].to_s == "ack"

          ack_lsn = message[:lsn].to_i
          @lock.synchronize do
            replica = @replicas[replica_id]
            if replica
              replica[:last_ack_lsn] = [replica[:last_ack_lsn].to_i, ack_lsn].max
              replica[:slot]&.advance(ack_lsn)
              persist_slots if replica[:slot]
              @stats[:replicated_lsn] = [@stats[:replicated_lsn].to_i, ack_lsn].max
            end
          end
        end
      rescue StandardError
        client.close rescue nil
      ensure
        if replica_id
          unregister_replica(replica_id)
        end
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
        return unless File.file?(@slot_path)

        data = JSON.parse(File.read(@slot_path), symbolize_names: true)
        data.fetch(:slots, {}).each do |name, slot_data|
          slot = ReplicationSlot.new(name, self)
          slot.confirmed_lsn = slot_data[:confirmed_lsn].to_i
          @replication_slots[slot.name] = slot
        end
      rescue JSON::ParserError => error
        raise RubyDB::ReplicationError, "Invalid replication slot catalog #{@slot_path}: #{error.message}"
      end

      def create_replication_slot(name)
        existing = @replication_slots[name.to_s]
        return existing if existing

        slot = ReplicationSlot.new(name, self)
        @replication_slots[name] = slot
        persist_slots
        slot
      end

      def drop_replication_slot(name)
        removed = @replication_slots.delete(name.to_s)
        persist_slots if removed
        removed
      end

      def persist_slots
        FileUtils.mkdir_p(File.dirname(@slot_path))
        payload = { slots: @replication_slots.transform_values { |slot| { confirmed_lsn: slot.confirmed_lsn } } }
        temporary = "#{@slot_path}.tmp-#{Process.pid}"
        File.write(temporary, JSON.generate(payload))
        File.rename(temporary, @slot_path)
      ensure
        File.delete(temporary) if defined?(temporary) && File.file?(temporary)
      end

      def notify_replicas(transaction_data, lsn)
        @stats[:replicated_lsn] = lsn
        entry = { lsn: lsn, timestamp: Time.now.iso8601, transaction_id: transaction_data[:id], data: transaction_data }
        @replicas.each_value do |replica|
          connection = replica[:connection]
          next unless connection
          next if replica[:last_lsn] && replica[:last_lsn] >= lsn
          send_replication_entry(connection, entry)
          replica[:last_lsn] = lsn
        rescue StandardError
          unregister_replica(replica[:id])
        end
      end

      def send_replication_entry(connection, entry)
        payload = JSON.generate(type: "replication_data", data: [entry]) + "\n"
        connection.write(payload)
        connection.flush
        @stats[:total_bytes_replicated] += payload.bytesize
      end

      def wait_for_sync_replicas
        deadline = Time.now + @config[:replication_timeout]
        loop do
          acknowledged = @replicas.values.count { |replica| replica[:last_ack_lsn] == @stats[:committed_lsn] }
          return true if acknowledged >= @config[:sync_replicas]
          raise ReplicationError, "Synchronous replica acknowledgment timed out" if Time.now >= deadline
          sleep(0.01)
        end
      end
    end
  end
end
