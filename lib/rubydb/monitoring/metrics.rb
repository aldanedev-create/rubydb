# frozen_string_literal: true

require "time"
require "thread"
require "json"
require "monitor"

module RubyDB
  module Monitoring
    # Metrics - Collects and manages metrics
    class Metrics
      attr_reader :stats

      # Metric types
      TYPE_COUNTER = :counter
      TYPE_GAUGE = :gauge
      TYPE_HISTOGRAM = :histogram
      TYPE_SUMMARY = :summary

      def initialize(config = {})
        @config = config
        @metrics = {}
        # Mutating helpers call counter/gauge/histogram, which also acquire
        # the lock. A reentrant monitor prevents self-deadlock while keeping
        # metric updates atomic across threads.
        @lock = Monitor.new
        @collectors = []
        @flush_interval = config[:flush_interval] || 60
        @retention_period = config[:retention_period] || 3600
        @stats = {
          metrics_count: 0,
          samples_collected: 0,
          flushes: 0,
          errors: 0
        }
        @flush_thread = nil
        @running = false
        @storage = []

        start_flush_thread if config[:auto_flush] != false
      end

      def counter(name, labels = {})
        @lock.synchronize do
          key = metric_key(name, labels)
          @metrics[key] ||= {
            type: TYPE_COUNTER,
            name: name,
            labels: labels,
            value: 0,
            created_at: Time.now,
            updated_at: Time.now
          }
          @metrics[key]
        end
      end

      def gauge(name, labels = {})
        @lock.synchronize do
          key = metric_key(name, labels)
          @metrics[key] ||= {
            type: TYPE_GAUGE,
            name: name,
            labels: labels,
            value: 0,
            created_at: Time.now,
            updated_at: Time.now
          }
          @metrics[key]
        end
      end

      def histogram(name, labels = {}, buckets = nil)
        @lock.synchronize do
          key = metric_key(name, labels)
          @metrics[key] ||= {
            type: TYPE_HISTOGRAM,
            name: name,
            labels: labels,
            buckets: buckets || [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10],
            values: [],
            created_at: Time.now,
            updated_at: Time.now
          }
          @metrics[key]
        end
      end

      def summary(name, labels = {})
        @lock.synchronize do
          key = metric_key(name, labels)
          @metrics[key] ||= {
            type: TYPE_SUMMARY,
            name: name,
            labels: labels,
            values: [],
            created_at: Time.now,
            updated_at: Time.now
          }
          @metrics[key]
        end
      end

      def increment(name, labels = {}, amount = 1)
        @lock.synchronize do
          metric = counter(name, labels)
          metric[:value] += amount
          metric[:updated_at] = Time.now
          @stats[:samples_collected] += 1
          metric[:value]
        end
      end

      def decrement(name, labels = {}, amount = 1)
        @lock.synchronize do
          metric = counter(name, labels)
          metric[:value] -= amount
          metric[:updated_at] = Time.now
          @stats[:samples_collected] += 1
          metric[:value]
        end
      end

      def set_gauge(name, labels = {}, value)
        @lock.synchronize do
          metric = gauge(name, labels)
          metric[:value] = value
          metric[:updated_at] = Time.now
          @stats[:samples_collected] += 1
          metric[:value]
        end
      end

      def observe_histogram(name, labels = {}, value)
        @lock.synchronize do
          metric = histogram(name, labels)
          metric[:values] << value
          metric[:updated_at] = Time.now
          @stats[:samples_collected] += 1
          metric[:values].size
        end
      end

      def observe_summary(name, labels = {}, value)
        @lock.synchronize do
          metric = summary(name, labels)
          metric[:values] << value
          metric[:updated_at] = Time.now
          @stats[:samples_collected] += 1
          metric[:values].size
        end
      end

      def get(name, labels = {})
        @lock.synchronize do
          key = metric_key(name, labels)
          @metrics[key]
        end
      end

      def get_all
        @lock.synchronize do
          @metrics.dup
        end
      end

      def get_by_name(name)
        @lock.synchronize do
          @metrics.select { |key, _| key.start_with?(name.to_s) }
        end
      end

      def reset(name, labels = {})
        @lock.synchronize do
          key = metric_key(name, labels)
          metric = @metrics[key]
          if metric
            case metric[:type]
            when TYPE_COUNTER
              metric[:value] = 0
            when TYPE_GAUGE
              metric[:value] = 0
            when TYPE_HISTOGRAM, TYPE_SUMMARY
              metric[:values] = []
            end
            metric[:updated_at] = Time.now
          end
          metric
        end
      end

      def clear
        @lock.synchronize do
          @metrics.clear
          @storage.clear
        end
      end

      def flush
        @lock.synchronize do
          return if @metrics.empty?

          snapshot = {
            timestamp: Time.now.iso8601,
            metrics: @metrics.dup
          }

          @storage << snapshot
          @stats[:flushes] += 1

          # Trim old data
          cutoff = Time.now - @retention_period
          @storage.delete_if { |s| Time.parse(s[:timestamp]) < cutoff }

          snapshot
        end
      end

      def query(start_time = nil, end_time = nil, name = nil)
        @lock.synchronize do
          start_time = Time.parse(start_time) if start_time.is_a?(String)
          end_time = Time.parse(end_time) if end_time.is_a?(String)

          results = @storage.select do |snapshot|
            time = Time.parse(snapshot[:timestamp])
            (start_time.nil? || time >= start_time) &&
            (end_time.nil? || time <= end_time)
          end

          if name
            results = results.map do |snapshot|
              {
                timestamp: snapshot[:timestamp],
                metrics: snapshot[:metrics].select { |key, _| key.start_with?(name.to_s) }
              }
            end
          end

          results
        end
      end

      def add_collector(collector)
        @collectors << collector
      end

      def collect
        @lock.synchronize do
          @collectors.each do |collector|
            begin
              collector.call(self)
            rescue => e
              @stats[:errors] += 1
            end
          end
        end
      end

      def stats
        @lock.synchronize do
          @stats.merge({
            metrics_count: @metrics.size,
            storage_size: @storage.size,
            running: @running,
            flush_interval: @flush_interval,
            retention_period: @retention_period
          })
        end
      end

      def to_json
        @lock.synchronize do
          JSON.generate({
            timestamp: Time.now.iso8601,
            metrics: @metrics,
            stats: @stats
          })
        end
      end

      # Render the current metrics using the Prometheus text exposition
      # format. Labels are escaped and metric names are normalized so this
      # output can be scraped without trusting caller-provided names.
      def to_prometheus
        @lock.synchronize do
          lines = []
          @metrics.each_value do |metric|
            name = prometheus_name(metric[:name])
            labels = prometheus_labels(metric[:labels])
            case metric[:type]
            when TYPE_COUNTER, TYPE_GAUGE
              lines << "#{name}#{labels} #{metric[:value]}"
            when TYPE_HISTOGRAM
              values = metric[:values]
              metric[:buckets].each do |bucket|
                count = values.count { |value| value <= bucket }
                lines << "#{name}_bucket#{prometheus_labels(metric[:labels].merge(le: bucket))} #{count}"
              end
              inf_label = "+Inf"
              lines << "#{name}_bucket#{prometheus_labels(metric[:labels].merge(le: inf_label))} #{values.size}"
              lines << "#{name}_count#{labels} #{values.size}"
              lines << "#{name}_sum#{labels} #{values.sum}"
            when TYPE_SUMMARY
              sorted = metric[:values].sort
              [0.5, 0.9, 0.99].each do |quantile|
                index = [(sorted.size * quantile).ceil - 1, 0].max
                value = sorted.empty? ? 0 : sorted[index]
                lines << "#{name}#{prometheus_labels(metric[:labels].merge(quantile: quantile))} #{value}"
              end
              lines << "#{name}_count#{labels} #{sorted.size}"
              lines << "#{name}_sum#{labels} #{sorted.sum}"
            end
          end
          lines.join("\n") + (lines.empty? ? "" : "\n")
        end
      end

      private

      def metric_key(name, labels)
        key = name.to_s.dup
        labels.each do |k, v|
          key << "_#{k}_#{v}"
        end
        key
      end

      def prometheus_name(name)
        normalized = name.to_s.gsub(/[^a-zA-Z0-9_:]/, "_")
        normalized = "rubydb_#{normalized}" unless normalized.start_with?("rubydb_")
        normalized
      end

      def prometheus_labels(labels)
        return "" if labels.empty?
        encoded = labels.sort_by { |key, _| key.to_s }.map do |key, value|
          escaped = value.to_s.gsub(/\\/, "\\\\").gsub('"', '\\"').gsub("\n", "\\n")
          "#{key}=\"#{escaped}\""
        end
        "{#{encoded.join(',')}}"
      end

      def start_flush_thread
        @running = true
        @flush_thread = Thread.new do
          while @running
            sleep(@flush_interval)
            begin
              collect
              flush
            rescue => e
              @stats[:errors] += 1
            end
          end
        end
      end
    end
  end
end
