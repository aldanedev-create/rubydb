# frozen_string_literal: true

module RubyDB
  module Chaos
    # NetworkFailure - Simulates network failures
    class NetworkFailure
      attr_reader :stats

      def initialize(engine, config = {})
        @engine = engine
        @config = config
        @failure_probability = config[:probability] || 0.1
        @max_failures = config[:max_failures] || 10
        @failure_types = [:drop_packet, :delay_packet, :corrupt_packet, :disconnect, :reconnect]
        @stats = {
          failures: 0,
          drop_packets: 0,
          delayed_packets: 0,
          corrupted_packets: 0,
          disconnects: 0,
          reconnects: 0,
          last_failure: nil,
          active_connections: []
        }
        @lock = Mutex.new
        @simulate_latency = config[:simulate_latency] || false
        @latency_ms = config[:latency_ms] || 100
      end

      def inject(connection = nil)
        @lock.synchronize do
          return if @stats[:failures] >= @max_failures

          if rand < @failure_probability
            perform_failure(connection)
          end
        end
      end

      def drop_packets(percentage = 0.1)
        @lock.synchronize do
          @stats[:failures] += 1
          @stats[:drop_packets] += 1
          @stats[:last_failure] = { type: :drop_packets, time: Time.now, percentage: percentage }
        end
      end

      def delay_packets(delay_ms = nil)
        @lock.synchronize do
          delay_ms ||= @latency_ms
          @stats[:failures] += 1
          @stats[:delayed_packets] += 1
          @stats[:last_failure] = { type: :delay_packets, time: Time.now, delay_ms: delay_ms }

          if @simulate_latency
            sleep(delay_ms / 1000.0)
          end
        end
      end

      def corrupt_packet()
        @lock.synchronize do
          @stats[:failures] += 1
          @stats[:corrupted_packets] += 1
          @stats[:last_failure] = { type: :corrupt_packet, time: Time.now }
        end
      end

      def disconnect(connection = nil)
        @lock.synchronize do
          @stats[:failures] += 1
          @stats[:disconnects] += 1
          @stats[:last_failure] = { type: :disconnect, time: Time.now }

          if connection
            connection.close if connection.respond_to?(:close)
            @stats[:active_connections].delete(connection)
          elsif @engine.respond_to?(:disconnect_all)
            @engine.disconnect_all
          end
        end
      end

      def reconnect(connection = nil)
        @lock.synchronize do
          @stats[:reconnects] += 1
          @stats[:last_failure] = { type: :reconnect, time: Time.now }

          if connection && connection.respond_to?(:reconnect)
            connection.reconnect
            @stats[:active_connections] << connection
          elsif @engine.respond_to?(:reconnect_all)
            @engine.reconnect_all
          end
        end
      end

      def simulate_latency(ms = nil)
        @lock.synchronize do
          ms ||= @latency_ms
          @simulate_latency = true
          @latency_ms = ms
          sleep(ms / 1000.0)
        end
      end

      def reset_network
        @lock.synchronize do
          @stats[:active_connections].clear
          @stats[:failures] = 0
          @stats[:drop_packets] = 0
          @stats[:delayed_packets] = 0
          @stats[:corrupted_packets] = 0
          @stats[:disconnects] = 0
          @stats[:reconnects] = 0
          @simulate_latency = false
        end
      end

      def stats
        @lock.synchronize do
          @stats.merge({
            failure_probability: @failure_probability,
            max_failures: @max_failures,
            simulate_latency: @simulate_latency,
            latency_ms: @latency_ms
          })
        end
      end

      private

      def perform_failure(connection)
        failure_type = @failure_types.sample

        case failure_type
        when :drop_packet
          drop_packets
        when :delay_packet
          delay_packets
        when :corrupt_packet
          corrupt_packet
        when :disconnect
          disconnect(connection)
        when :reconnect
          reconnect(connection)
        end
      end
    end
  end
end