# frozen_string_literal: true

require "securerandom"
require "date"

module RubyDB
  module Fuzz
    module Generators
      # ValueGenerator - Generates random values for different data types
      class ValueGenerator
        attr_reader :stats

        def initialize(config = {})
          @config = config
          @seed = config[:seed]
          @stats = {
            values_generated: 0,
            by_type: Hash.new(0)
          }
          @lock = Mutex.new

          srand(@seed) if @seed
        end

        def generate(type, options = {})
          @lock.synchronize do
            @stats[:values_generated] += 1
            @stats[:by_type][type] += 1

            case type.to_sym
            when :integer
              generate_integer(options)
            when :bigint
              generate_bigint(options)
            when :smallint
              generate_smallint(options)
            when :float
              generate_float(options)
            when :decimal
              generate_decimal(options)
            when :boolean
              generate_boolean
            when :text
              generate_text(options)
            when :varchar
              generate_varchar(options)
            when :char
              generate_char(options)
            when :blob
              generate_blob(options)
            when :date
              generate_date
            when :time
              generate_time
            when :timestamp
              generate_timestamp
            when :json
              generate_json
            when :uuid
              generate_uuid
            when :null
              nil
            else
              generate_text(options)
            end
          end
        end

        def generate_batch(type, count, options = {})
          @lock.synchronize do
            count.times.map { generate(type, options) }
          end
        end

        def generate_row(schema)
          @lock.synchronize do
            row = {}
            schema.each do |column, type|
              row[column] = generate(type)
            end
            row
          end
        end

        def generate_rows(schema, count)
          @lock.synchronize do
            count.times.map { generate_row(schema) }
          end
        end

        private

        def generate_integer(options)
          min = options[:min] || -2147483648
          max = options[:max] || 2147483647
          rand(min..max)
        end

        def generate_bigint(options)
          min = options[:min] || -9223372036854775808
          max = options[:max] || 9223372036854775807
          rand(min..max)
        end

        def generate_smallint(options)
          min = options[:min] || -32768
          max = options[:max] || 32767
          rand(min..max)
        end

        def generate_float(options)
          min = options[:min] || -10000.0
          max = options[:max] || 10000.0
          rand(min..max)
        end

        def generate_decimal(options)
          precision = options[:precision] || 10
          scale = options[:scale] || 2

          integer_part = rand(10 ** (precision - scale - 1)..10 ** (precision - scale))
          decimal_part = rand(10 ** (scale - 1)..10 ** scale)
          value = "#{integer_part}.#{decimal_part}".to_f

          value *= -1 if rand < 0.3
          value
        end

        def generate_boolean
          [true, false].sample
        end

        def generate_text(options)
          length = options[:length] || rand(1..1000)
          chars = options[:charset] || ("a".."z").to_a + ("A".."Z").to_a + ("0".."9").to_a + [" "]
          (0...length).map { chars.sample }.join
        end

        def generate_varchar(options)
          max_length = options[:limit] || 255
          length = options[:length] || rand(1..[max_length, 100].min)
          generate_text(options.merge(length: length))
        end

        def generate_char(options)
          length = options[:length] || options[:limit] || 10
          text = generate_text(options.merge(length: length))
          text.ljust(length, " ")
        end

        def generate_blob(options)
          length = options[:length] || rand(1..1024)
          SecureRandom.random_bytes(length)
        end

        def generate_date
          start_date = Date.parse("1970-01-01")
          end_date = Date.parse("2100-12-31")
          start_date + rand((end_date - start_date).to_i)
        end

        def generate_time
          hour = rand(0..23)
          minute = rand(0..59)
          second = rand(0..59)
          microsecond = rand(0..999999)
          Time.new(2000, 1, 1, hour, minute, second, microsecond)
        end

        def generate_timestamp
          # Generate timestamp between 1970 and 2100
          start_time = Time.new(1970, 1, 1).to_i
          end_time = Time.new(2100, 12, 31).to_i
          Time.at(rand(start_time..end_time))
        end

        def generate_json
          depth = rand(1..5)
          generate_json_value(depth)
        end

        def generate_json_value(depth)
          if depth == 0
            case rand(0..5)
            when 0 then rand(1000)
            when 1 then rand * 1000
            when 2 then [true, false].sample
            when 3 then SecureRandom.hex(10)
            when 4 then nil
            else [rand(100), generate_json_value(depth - 1)]
            end
          else
            case rand(0..3)
            when 0
              # Object
              obj = {}
              rand(1..5).times do
                key = SecureRandom.alphanumeric(rand(3..10))
                obj[key] = generate_json_value(depth - 1)
              end
              obj
            when 1
              # Array
              Array.new(rand(1..10)) { generate_json_value(depth - 1) }
            when 2
              SecureRandom.hex(10)
            else
              rand(1000)
            end
          end
        end

        def generate_uuid
          SecureRandom.uuid
        end

        def stats
          @lock.synchronize do
            @stats.merge({
              seed: @seed,
              total_generated: @stats[:values_generated]
            })
          end
        end
      end
    end
  end
end