# frozen_string_literal: true

require "socket"
require "time"
require "json"

module RubyDB
  module Replication
    # ReplicationStream - Streams replication data to replicas
    class ReplicationStream
      attr_reader :stats

      # Stream states
      STATE_INIT = :init
      STATE_STREAMING = :streaming
      STATE_PAUSED = :paused
      STATE_ERROR = :error
      STATE_CLOSED = :closed

      def initialize(primary, config = {})
        @primary = primary
        @config = config
        @replicas = {}
        @streams = {}
        @state = STATE_INIT
        @stats = {
          bytes_streamed: 0,
          transactions_streamed: 0,
          replicas_connected: 0,
          total_replicas: 0,
          errors: 0,
          stream_time_ms: 0
        }
        @lock = Mutex.new
        @running = false
        @stream_thread = nil
        @buffer = []
        @buffer_size = config[:buffer_size] || 1024 * 1024
        @flush_interval = config[:flush_interval] || 1
        @max_replicas = config[:max_replicas] || 10
      end

      def start
        @lock.synchronize do
          return if @running

          @running = true
          @state = STATE_STREAMING
          @stream_thread = Thread.new { stream_loop }

          puts "Replication stream started"
          true
        end
      end

      def stop
        @lock.synchronize do
          return unless @running

          @running = false
          @state = STATE_CLOSED

          @stream_thread&.kill
          @stream_thread = nil

          close_all_streams
          true
        end
      end

      def add_replica(replica_id, connection)
        @lock.synchronize do
          if @replicas.size >= @max_replicas
            connection.close
            return false
          end

          stream = create_stream(connection)
          @replicas[replica_id] = {
            id: replica_id,
            connection: connection,
            stream: stream,
            connected_at: Time.now,
            last_lsn: nil,
            lag_bytes: 0
          }

          @stats[:replicas_connected] = @replicas.size
          @stats[:total_replicas] += 1

          true
        end
      end

      def remove_replica(replica_id)
        @lock.synchronize do
          replica = @replicas.delete(replica_id)
          return false unless replica

          replica[:connection].close
          @stats[:replicas_connected] = @replicas.size
          true
        end
      end

      def stream_transaction(transaction_data, lsn)
        @lock.synchronize do
          return false if @state != STATE_STREAMING

          @buffer << { data: transaction_data, lsn: lsn }

          if @buffer.size >= @buffer_size
            flush_buffer
          end

          @stats[:transactions_streamed] += 1
          true
        end
      end

      def flush_buffer
        @lock.synchronize do
          return if @buffer.empty?

          start_time = Time.now

          @replicas.each do |id, replica|
            begin
              stream_data = JSON.generate({
                type: "replication_data",
                data: @buffer,
                timestamp: Time.now.iso8601
              })

              replica[:stream].write(stream_data + "\n")
              replica[:stream].flush

              @stats[:bytes_streamed] += stream_data.bytesize

            rescue => e
              @stats[:errors] += 1
              remove_replica(id)
            end
          end

          @buffer.clear

          elapsed_ms = (Time.now - start_time) * 1000
          @stats[:stream_time_ms] += elapsed_ms
        end
      end

      def get_replica_status(replica_id)
        @lock.synchronize do
          replica = @replicas[replica_id]
          return nil unless replica

          {
            id: replica[:id],
            connected_at: replica[:connected_at].iso8601,
            last_lsn: replica[:last_lsn],
            lag_bytes: replica[:lag_bytes]
          }
        end
      end

      def stats
        @lock.synchronize do
          @stats.merge({
            state: @state,
            running: @running,
            replicas: @replicas.size,
            buffer_size: @buffer.size,
            max_replicas: @max_replicas
          })
        end
      end

      private

      def stream_loop
        while @running
          sleep(@flush_interval)
          flush_buffer
        end
      end

      def create_stream(connection)
        connection
      end

      def close_all_streams
        @replicas.each do |id, replica|
          replica[:connection].close
        end
        @replicas.clear
        @stats[:replicas_connected] = 0
      end
    end
  end
end