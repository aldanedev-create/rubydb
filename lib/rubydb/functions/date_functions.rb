# frozen_string_literal: true

require "date"
require "time"

module RubyDB
  module Functions
    # DateFunctions - All date-related functions
    class DateFunctions
      # NOW - Current timestamp
      class Now < ScalarFunction
        def initialize
          super(:now,
            description: "Current timestamp",
            category: :date,
            min_args: 0,
            max_args: 0,
            return_type: :timestamp,
            deterministic: false,
            immutable: false
          )
        end

        def execute_scalar(args)
          Time.now
        end
      end

      # CURRENT_DATE - Current date
      class CurrentDate < ScalarFunction
        def initialize
          super(:current_date,
            description: "Current date",
            category: :date,
            min_args: 0,
            max_args: 0,
            return_type: :date,
            deterministic: false,
            immutable: false
          )
        end

        def execute_scalar(args)
          Date.today
        end
      end

      # CURRENT_TIME - Current time
      class CurrentTime < ScalarFunction
        def initialize
          super(:current_time,
            description: "Current time",
            category: :date,
            min_args: 0,
            max_args: 0,
            return_type: :time,
            deterministic: false,
            immutable: false
          )
        end

        def execute_scalar(args)
          Time.now
        end
      end

      # DATE - Convert to date
      class Date < ScalarFunction
        def initialize
          super(:date,
            description: "Convert to date",
            category: :date,
            min_args: 1,
            max_args: 1,
            return_type: :date,
            deterministic: true,
            immutable: true
          )
        end

        def execute_scalar(args)
          return nil if args[0].nil?
          arg = args[0]
          if arg.is_a?(Time) || arg.is_a?(DateTime)
            arg.to_date
          elsif arg.is_a?(String)
            ::Date.parse(arg) rescue nil
          else
            nil
          end
        end
      end

      # EXTRACT - Extract part of date
      class Extract < ScalarFunction
        def initialize
          super(:extract,
            description: "Extract part of date",
            category: :date,
            min_args: 2,
            max_args: 2,
            return_type: :integer,
            deterministic: true,
            immutable: true
          )
        end

        def execute_scalar(args)
          return nil if args[1].nil?

          part = args[0].to_s.downcase
          date = args[1]

          case part
          when "year", "y"
            date.year
          when "month", "mon"
            date.month
          when "day", "d"
            date.day
          when "hour", "h"
            date.hour if date.respond_to?(:hour)
          when "minute", "min"
            date.min if date.respond_to?(:min)
          when "second", "sec"
            date.sec if date.respond_to?(:sec)
          when "dow", "dayofweek"
            date.wday
          when "doy", "dayofyear"
            date.yday if date.respond_to?(:yday)
          else
            nil
          end
        end
      end

      # DATE_ADD - Add interval to date
      class DateAdd < ScalarFunction
        def initialize
          super(:date_add,
            description: "Add interval to date",
            category: :date,
            min_args: 3,
            max_args: 3,
            return_type: :timestamp,
            deterministic: true,
            immutable: true
          )
        end

        def execute_scalar(args)
          return nil if args[0].nil?

          date = args[0]
          interval = args[1].to_i
          unit = args[2].to_s.downcase

          case unit
          when "year", "years"
            date + interval * 365 * 24 * 60 * 60
          when "month", "months"
            date + interval * 30 * 24 * 60 * 60
          when "day", "days"
            date + interval * 24 * 60 * 60
          when "hour", "hours"
            date + interval * 60 * 60
          when "minute", "minutes"
            date + interval * 60
          when "second", "seconds"
            date + interval
          else
            nil
          end
        end
      end

      # DATE_DIFF - Difference between dates
      class DateDiff < ScalarFunction
        def initialize
          super(:date_diff,
            description: "Difference between dates",
            category: :date,
            min_args: 3,
            max_args: 3,
            return_type: :integer,
            deterministic: true,
            immutable: true
          )
        end

        def execute_scalar(args)
          return nil if args[0].nil? || args[1].nil?

          date1 = args[0]
          date2 = args[1]
          unit = args[2].to_s.downcase

          diff = (date2.to_i - date1.to_i).abs

          case unit
          when "year", "years"
            diff / (365 * 24 * 60 * 60)
          when "month", "months"
            diff / (30 * 24 * 60 * 60)
          when "day", "days"
            diff / (24 * 60 * 60)
          when "hour", "hours"
            diff / (60 * 60)
          when "minute", "minutes"
            diff / 60
          when "second", "seconds"
            diff
          else
            nil
          end
        end
      end

      # DATE_FORMAT - Format date
      class DateFormat < ScalarFunction
        def initialize
          super(:date_format,
            description: "Format date",
            category: :date,
            min_args: 2,
            max_args: 2,
            return_type: :text,
            deterministic: true,
            immutable: true
          )
        end

        def execute_scalar(args)
          return nil if args[0].nil? || args[1].nil?

          date = args[0]
          format = args[1].to_s

          # Simple format substitutions
          formatted = format
          formatted = formatted.gsub("%Y", date.year.to_s)
          formatted = formatted.gsub("%y", date.year.to_s[-2..-1])
          formatted = formatted.gsub("%m", date.month.to_s.rjust(2, "0"))
          formatted = formatted.gsub("%d", date.day.to_s.rjust(2, "0"))
          formatted = formatted.gsub("%H", date.hour.to_s.rjust(2, "0")) if date.respond_to?(:hour)
          formatted = formatted.gsub("%M", date.min.to_s.rjust(2, "0")) if date.respond_to?(:min)
          formatted = formatted.gsub("%S", date.sec.to_s.rjust(2, "0")) if date.respond_to?(:sec)

          formatted
        end
      end

      # TO_TIMESTAMP - Convert string to timestamp
      class ToTimestamp < ScalarFunction
        def initialize
          super(:to_timestamp,
            description: "Convert string to timestamp",
            category: :date,
            min_args: 1,
            max_args: 1,
            return_type: :timestamp,
            deterministic: true,
            immutable: true
          )
        end

        def execute_scalar(args)
          return nil if args[0].nil?
          begin
            Time.parse(args[0].to_s)
          rescue
            nil
          end
        end
      end
    end
  end
end