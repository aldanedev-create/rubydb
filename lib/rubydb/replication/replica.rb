# frozen_string_literal: true

require "socket"
require "time"
require "monitor"
require "json"
require "fileutils"

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
        @lock = Monitor.new
        @running = false
        @replication_thread = nil
        @recovery = nil
        @retry_interval = config[:retry_interval] || 5
        @max_retry_attempts = config[:max_retry_attempts] || 10
        @retry_count = 0
        @state_path = config[:state_path] || "#{@engine.path}.replica_state.json"
        load_state
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

      def running?
        @lock.synchronize { @running }
      end

      def promote_to_primary
        @lock.synchronize do
          # Stop replication
          stop

          # The manager owns creation of the primary listener. The storage
          # engine remains writable, so promotion only ends the stream here.
          @state = STATE_SYNCED
          true
        end
      end

      def replay_transaction(transaction_data, lsn = nil)
        @lock.synchronize do
          # Apply transaction to engine
          @engine.apply_transaction(transaction_data)
          @stats[:transactions_replayed] += 1
          @last_replayed_lsn = lsn || transaction_data[:lsn]
          persist_state

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

            @connection.write(JSON.generate(handshake) + "\n")
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
        data.to_s.each_line do |line|
          message = JSON.parse(line, symbolize_names: true)
          next unless message[:type].to_s == "replication_data"

          Array(message[:data]).each do |entry|
            next if entry[:lsn] && @last_replayed_lsn && entry[:lsn] <= @last_replayed_lsn
            replay_transaction(entry[:data] || entry, entry[:lsn])
            @last_received_lsn = entry[:lsn]
            persist_state
            @connection&.write(JSON.generate(type: "ack", lsn: @last_received_lsn) + "\n")
          end
        end
      end

      def catch_up
        @state = if @last_received_lsn && @last_received_lsn == @last_replayed_lsn
                   STATE_SYNCED
                 else
                   STATE_STREAMING
                 end
      end

      def load_state
        return unless File.file?(@state_path)
        state = JSON.parse(File.read(@state_path), symbolize_names: true)
        @last_received_lsn = state[:last_received_lsn]
        @last_replayed_lsn = state[:last_replayed_lsn]
      rescue JSON::ParserError => error
        raise RubyDB::ReplicationError, "Invalid replica state #{@state_path}: #{error.message}"
      end

      def persist_state
        FileUtils.mkdir_p(File.dirname(@state_path))
        temporary = "#{@state_path}.tmp-#{Process.pid}"
        File.write(temporary, JSON.generate(
          last_received_lsn: @last_received_lsn,
          last_replayed_lsn: @last_replayed_lsn,
          updated_at: Time.now.iso8601
        ))
        File.rename(temporary, @state_path)
      ensure
        File.delete(temporary) if defined?(temporary) && File.file?(temporary)
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
