# frozen_string_literal: true

module RubyDB
  module Monitoring
    # Statistics - Statistical calculations
    class Statistics
      attr_reader :stats

      def initialize
        @stats = {
          calculations: 0,
          errors: 0
        }
        @lock = Mutex.new
      end

      def mean(values)
        return 0 if values.empty?
        values.sum / values.size.to_f
      end

      def median(values)
        return 0 if values.empty?
        sorted = values.sort
        mid = sorted.size / 2
        if sorted.size.even?
          (sorted[mid - 1] + sorted[mid]) / 2.0
        else
          sorted[mid]
        end
      end

      def mode(values)
        return nil if values.empty?
        freq = values.each_with_object(Hash.new(0)) { |v, h| h[v] += 1 }
        max_freq = freq.values.max
        freq.select { |_, f| f == max_freq }.keys
      end

      def variance(values)
        return 0 if values.size < 2
        m = mean(values)
        values.sum { |v| (v - m) ** 2 } / (values.size - 1).to_f
      end

      def standard_deviation(values)
        Math.sqrt(variance(values))
      end

      def percentile(values, p)
        return 0 if values.empty?
        sorted = values.sort
        index = (p / 100.0) * (sorted.size - 1)
        if index.to_i == index
          sorted[index.to_i]
        else
          lower = sorted[index.floor]
          upper = sorted[index.ceil]
          lower + (upper - lower) * (index - index.floor)
        end
      end

      def min(values)
        values.min || 0
      end

      def max(values)
        values.max || 0
      end

      def sum(values)
        values.sum
      end

      def count(values)
        values.size
      end

      def histogram(values, bins = 10)
        return {} if values.empty?
        min_val = min(values)
        max_val = max(values)
        range = max_val - min_val
        bin_width = range / bins.to_f

        histogram = {}
        bins.times do |i|
          low = min_val + i * bin_width
          high = low + bin_width
          key = "#{low.round(2)}-#{high.round(2)}"
          histogram[key] = values.count { |v| v >= low && v < high }
        end

        histogram
      end

      def moving_average(values, window = 10)
        return [] if values.empty?
        result = []
        values.each_with_index do |v, i|
          start_idx = [0, i - window + 1].max
          window_values = values[start_idx..i]
          result << mean(window_values)
        end
        result
      end

      def exponential_moving_average(values, alpha = 0.1)
        return [] if values.empty?
        result = []
        ema = values.first
        values.each do |v|
          ema = alpha * v + (1 - alpha) * ema
          result << ema
        end
        result
      end

      def z_score(values, value)
        return 0 if values.empty?
        m = mean(values)
        sd = standard_deviation(values)
        return 0 if sd == 0
        (value - m) / sd
      end

      def correlation(x_values, y_values)
        return 0 if x_values.size != y_values.size || x_values.empty?
        n = x_values.size
        sum_x = x_values.sum
        sum_y = y_values.sum
        sum_xy = x_values.zip(y_values).sum { |x, y| x * y }
        sum_x2 = x_values.sum { |x| x * x }
        sum_y2 = y_values.sum { |y| y * y }

        numerator = n * sum_xy - sum_x * sum_y
        denominator = Math.sqrt((n * sum_x2 - sum_x * sum_x) * (n * sum_y2 - sum_y * sum_y))
        return 0 if denominator == 0
        numerator / denominator
      end

      def calculate_summary(values)
        @stats[:calculations] += 1
        {
          count: count(values),
          sum: sum(values),
          mean: mean(values),
          median: median(values),
          min: min(values),
          max: max(values),
          variance: variance(values),
          std_dev: standard_deviation(values),
          p25: percentile(values, 25),
          p50: percentile(values, 50),
          p75: percentile(values, 75),
          p90: percentile(values, 90),
          p95: percentile(values, 95),
          p99: percentile(values, 99)
        }
      rescue => e
        @stats[:errors] += 1
        {}
      end

      def stats
        @stats
      end
    end
  end
end