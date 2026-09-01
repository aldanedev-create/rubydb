# frozen_string_literal: true

require "socket"
require "time"

module RubyDB
  module Replication
    # Replica - Replica database server
    class Replica
      attr_reader :config, :engine, :primary_host, :primary_port
      attr_reader :stats

      # Replica states
      STATE_INIT = :init
      STATE_CONNECTING = :connecting
      STATE_STREAMING = :streaming
      STATE_REPLAYING = :replaying
      STATE_CATCHING_UP = :catching_up
      STATE_SYNCED = :synced
      STATE_DISCONNECTED = :disconnected
      STATE_FAILED = :failed

      def initialize(engine, config = {})
        @engine = engine
        @config = config
        @primary_host = config[:primary_host] || "localhost"
        @primary_port = config[:primary_port] || 7433
        @replication_port = config[:replication_port] || 7434
        @state = STATE_INIT
        @connection = nil
        @replication_stream = nil
        @last_received_lsn = nil
        @last_replayed_lsn = nil
        @catchup_start_time = nil
        @stats = {
          bytes_received: 0,
          transactions_replayed: 0,
          replication_lag_ms: 0,
          reconnect_attempts: 0,
          last_connect_time: nil,
          last_disconnect_time: nil,
          total_uptime_ms: 0
        }
        @lock = Mutex.new
        @running = false
        @replication_thread = nil
        @recovery = nil
        @retry_interval = config[:retry_interval] || 5
        @max_retry_attempts = config[:max_retry_attempts] || 10
        @retry_count = 0
      end

      def start
        @lock.synchronize do
          return if @running

          @running = true
          @state = STATE_CONNECTING
          @replication_thread = Thread.new { replication_loop }

          puts "Replica started, connecting to primary at #{@primary_host}:#{@replication_port}"
          true
        end
      end

      def stop
        @lock.synchronize do
          return unless @running

          @running = false
          @state = STATE_DISCONNECTED

          @replication_thread&.kill
          @replication_thread = nil

          disconnect
          true
        end
      end

      def promote_to_primary
        @lock.synchronize do
          # Stop replication
          stop

          # Promote to primary
          @engine.promote_to_primary

          puts "Replica promoted to primary"
          true
        end
      end

      def replay_transaction(transaction_data)
        @lock.synchronize do
          @stats[:transactions_replayed] += 1
          @last_replayed_lsn = transaction_data[:lsn]

          # Apply transaction to engine
          @engine.apply_transaction(transaction_data)

          true
        end
      end

      def replication_status
        @lock.synchronize do
          {
            state: @state,
            primary_host: @primary_host,
            primary_port: @primary_port,
            last_received_lsn: @last_received_lsn,
            last_replayed_lsn: @last_replayed_lsn,
            lag_ms: @stats[:replication_lag_ms],
            bytes_received: @stats[:bytes_received],
            transactions_replayed: @stats[:transactions_replayed],
            connected: @state == STATE_STREAMING || @state == STATE_SYNCED
          }
        end
      end

      private

      def replication_loop
        while @running
          begin
            case @state
            when STATE_INIT, STATE_CONNECTING
              connect_to_primary
            when STATE_STREAMING
              stream_replication
            when STATE_CATCHING_UP
              catch_up
            when STATE_SYNCED
              sleep(1)
            when STATE_DISCONNECTED, STATE_FAILED
              reconnect
            end
          rescue => e
            @state = STATE_FAILED
            @stats[:reconnect_attempts] += 1
            sleep(@retry_interval)
          end
        end
      end

      def connect_to_primary
        @lock.synchronize do
          begin
            @connection = TCPSocket.new(@primary_host, @replication_port)
            @state = STATE_CONNECTING
            @stats[:last_connect_time] = Time.now

            # Send replica handshake
            handshake = {
              type: "replica_handshake",
              replica_id: @config[:replica_id] || "replica_#{Process.pid}",
              protocol_version: 1,
              wal_position: @last_replayed_lsn || 0
            }

            @connection.write(JSON.generate(handshake))
            response = JSON.parse(@connection.readline)

            if response["success"]
              @state = STATE_STREAMING
              @stats[:reconnect_attempts] = 0
              @retry_count = 0
              puts "Connected to primary as replica"
            else
              @state = STATE_FAILED
            end

          rescue => e
            @state = STATE_FAILED
            @stats[:reconnect_attempts] += 1
            raise
          end
        end
      end

      def stream_replication
        while @running && @state == STATE_STREAMING
          begin
            # Read replication data
            if @connection
              data = @connection.readpartial(4096)
              @stats[:bytes_received] += data.bytesize

              # Process replication data
              process_replication_data(data)
            else
              @state = STATE_DISCONNECTED
              break
            end
          rescue EOFError, Errno::ECONNRESET
            @state = STATE_DISCONNECTED
            break
          rescue => e
            @state = STATE_FAILED
            break
          end
        end
      end

      def process_replication_data(data)
        # In production, would parse and apply replication data
        # This would include WAL records, transaction data, etc.

        # For each transaction received
        # replay_transaction(transaction_data)

        @last_received_lsn = Time.now.to_i
      end

      def catch_up
        # In production, would catch up on missed transactions
        sleep(1)
        @state = STATE_SYNCED if @last_received_lsn >= @last_replayed_lsn
      end

      def reconnect
        @retry_count += 1

        if @retry_count > @max_retry_attempts
          @state = STATE_FAILED
          return
        end

        sleep(@retry_interval * @retry_count)
        @state = STATE_CONNECTING
      end

      def disconnect
        @connection&.close
        @connection = nil
        @state = STATE_DISCONNECTED
        @stats[:last_disconnect_time] = Time.now
      end
    end
  end
end