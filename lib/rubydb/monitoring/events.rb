# frozen_string_literal: true

require "time"
require "thread"

module RubyDB
  module Monitoring
    # Events - Event system
    class Events
      attr_reader :stats

      # Event types
      EVENT_CONNECT = :connect
      EVENT_DISCONNECT = :disconnect
      EVENT_QUERY = :query
      EVENT_TRANSACTION = :transaction
      EVENT_ERROR = :error
      EVENT_WARNING = :warning
      EVENT_CHECKPOINT = :checkpoint
      EVENT_RECOVERY = :recovery
      EVENT_REPLICATION = :replication
      EVENT_BACKUP = :backup
      EVENT_RESTORE = :restore
      EVENT_MIGRATION = :migration
      EVENT_SCHEMA_CHANGE = :schema_change
      EVENT_SYSTEM = :system

      def initialize(config = {})
        @config = config
        @listeners = {}
        @event_history = []
        @max_history = config[:max_history] || 10000
        @lock = Mutex.new
        @stats = {
          events_emitted: 0,
          events_processed: 0,
          listeners_registered: 0,
          listeners_removed: 0,
          errors: 0
        }
        @async = config[:async] != false
        @queue = Queue.new if @async
        @processor_thread = nil

        start_processor if @async
      end

      def on(event_type, &block)
        @lock.synchronize do
          @listeners[event_type] ||= []
          @listeners[event_type] << block
          @stats[:listeners_registered] += 1
        end
      end

      def off(event_type, block = nil)
        @lock.synchronize do
          return false unless @listeners[event_type]

          if block
            @listeners[event_type].delete(block)
          else
            @listeners[event_type].clear
          end
          @stats[:listeners_removed] += 1
          true
        end
      end

      def emit(event_type, data = {})
        @lock.synchronize do
          @stats[:events_emitted] += 1

          event = {
            id: generate_event_id,
            type: event_type,
            timestamp: Time.now.iso8601,
            data: data,
            pid: Process.pid,
            thread: Thread.current.object_id
          }

          @event_history << event
          if @event_history.size > @max_history
            @event_history.shift
          end

          if @async
            @queue << event
          else
            process_event(event)
          end

          event
        end
      end

      def process_event(event)
        @lock.synchronize do
          @stats[:events_processed] += 1
          listeners = @listeners[event[:type]] || []
          listeners.each do |listener|
            begin
              listener.call(event)
            rescue => e
              @stats[:errors] += 1
            end
          end
        end
      end

      def history(event_type = nil)
        @lock.synchronize do
          if event_type
            @event_history.select { |e| e[:type] == event_type }
          else
            @event_history.dup
          end
        end
      end

      def clear_history
        @lock.synchronize do
          @event_history.clear
        end
      end

      def stats
        @lock.synchronize do
          @stats.merge({
            history_size: @event_history.size,
            max_history: @max_history,
            listeners_count: @listeners.size,
            async: @async,
            queue_size: @async ? @queue.size : 0
          })
        end
      end

      private

      def generate_event_id
        "evt_#{Time.now.to_i}_#{rand(10000)}"
      end

      def start_processor
        @processor_thread = Thread.new do
          while true
            begin
              event = @queue.pop
              process_event(event)
            rescue => e
              @stats[:errors] += 1
            end
          end
        end
      end
    end
  end
end