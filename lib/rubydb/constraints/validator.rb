# frozen_string_literal: true

require "set"

module RubyDB
  module Constraints
    # Validator - Validates rows against all constraints
    class Validator
      attr_reader :constraints, :stats

      def initialize
        @constraints = {
          primary_key: [],
          foreign_key: [],
          unique: [],
          not_null: [],
          check: []
        }
        @stats = {
          validations: 0,
          valid_rows: 0,
          invalid_rows: 0,
          constraint_violations: 0,
          validation_time_ms: 0,
          total_validation_time_ms: 0,
          avg_validation_time_ms: 0
        }
        @lock = Mutex.new
        @constraint_cache = {}
        @deferred_constraints = []
      end

      def add_constraint(constraint)
        @lock.synchronize do
          type = constraint.type
          @constraints[type] ||= []
          @constraints[type] << constraint
          @constraint_cache[constraint.name] = constraint
          @constraint_cache["#{constraint.table_name}:#{constraint.name}"] = constraint
        end
      end

      def remove_constraint(name)
        @lock.synchronize do
          @constraints.each do |type, list|
            list.delete_if { |c| c.name == name }
          end
          @constraint_cache.delete(name)
          @constraint_cache.each do |key, c|
            if c.name == name
              @constraint_cache.delete(key)
            end
          end
        end
      end

      def get_constraint(name)
        @constraint_cache[name]
      end

      def get_constraints_for_table(table_name)
        @lock.synchronize do
          result = []
          @constraints.each do |_, list|
            list.each do |c|
              result << c if c.table_name == table_name
            end
          end
          result
        end
      end

      def validate_row(row, table_name, options = {})
        @lock.synchronize do
          start_time = Time.now
          @stats[:validations] += 1

          result = {
            valid: true,
            errors: [],
            warnings: [],
            constraints_checked: [],
            constraints_passed: [],
            constraints_failed: []
          }

          constraints = get_constraints_for_table(table_name)

          constraints.each do |constraint|
            next unless constraint.enabled?
            next if options[:skip] && options[:skip].include?(constraint.type)

            @stats[:constraint_violations] += 1
            result[:constraints_checked] << constraint.name

            if constraint.validate(row)
              result[:constraints_passed] << constraint.name
            else
              result[:valid] = false
              result[:constraints_failed] << constraint.name
              result[:errors] << {
                constraint: constraint.name,
                type: constraint.type,
                message: constraint.validation_errors.last
              }
            end
          end

          # Handle deferred constraints
          if options[:defer] != false
            @deferred_constraints.each do |dc|
              next unless dc[:table] == table_name

              if dc[:constraint].validate(row)
                result[:constraints_passed] << dc[:constraint].name
              else
                result[:valid] = false
                result[:constraints_failed] << dc[:constraint].name
                result[:errors] << {
                  constraint: dc[:constraint].name,
                  type: dc[:constraint].type,
                  message: "Deferred constraint violation"
                }
              end
            end
          end

          elapsed_ms = (Time.now - start_time) * 1000
          @stats[:total_validation_time_ms] += elapsed_ms
          @stats[:avg_validation_time_ms] = @stats[:total_validation_time_ms] / @stats[:validations]

          if result[:valid]
            @stats[:valid_rows] += 1
          else
            @stats[:invalid_rows] += 1
          end

          result
        end
      end

      def validate_rows(rows, table_name, options = {})
        @lock.synchronize do
          start_time = Time.now
          @stats[:validations] += 1

          results = {
            valid: [],
            invalid: [],
            errors: [],
            summary: {
              total: rows.size,
              valid: 0,
              invalid: 0,
              constraint_violations: 0
            }
          }

          constraints = get_constraints_for_table(table_name)

          # Group constraints by type for batch validation
          constraints_by_type = {}
          constraints.each do |c|
            next unless c.enabled?
            next if options[:skip] && options[:skip].include?(c.type)

            constraints_by_type[c.type] ||= []
            constraints_by_type[c.type] << c
          end

          # Validate each row
          rows.each do |row|
            row_valid = true
            row_errors = []

            constraints_by_type.each do |type, list|
              list.each do |constraint|
                @stats[:constraint_violations] += 1

                if constraint.validate(row)
                  # Passed
                else
                  row_valid = false
                  row_errors << {
                    constraint: constraint.name,
                    type: type,
                    message: constraint.validation_errors.last
                  }
                end
              end
            end

            if row_valid
              results[:valid] << row
              results[:summary][:valid] += 1
            else
              results[:invalid] << row
              results[:summary][:invalid] += 1
              results[:errors] << { row: row, errors: row_errors }
              results[:summary][:constraint_violations] += row_errors.size
            end
          end

          elapsed_ms = (Time.now - start_time) * 1000
          @stats[:total_validation_time_ms] += elapsed_ms
          @stats[:avg_validation_time_ms] = @stats[:total_validation_time_ms] / @stats[:validations]

          @stats[:valid_rows] += results[:summary][:valid]
          @stats[:invalid_rows] += results[:summary][:invalid]

          results
        end
      end

      def validate_batch(table_name, rows, options = {})
        validate_rows(rows, table_name, options)
      end

      def defer_constraint(constraint, table_name)
        @lock.synchronize do
          @deferred_constraints << {
            constraint: constraint,
            table: table_name,
            deferred_at: Time.now
          }
        end
      end

      def validate_deferred(table_name = nil)
        @lock.synchronize do
          results = {
            valid: true,
            errors: [],
            constraints_checked: []
          }

          deferred = if table_name
            @deferred_constraints.select { |dc| dc[:table] == table_name }
          else
            @deferred_constraints
          end

          deferred.each do |dc|
            # In production, we would re-validate the rows
            # For now, mark as validated
            dc[:constraint].instance_variable_set(:@validated, true)
            results[:constraints_checked] << dc[:constraint].name
          end

          @deferred_constraints.clear if table_name.nil?
          results
        end
      end

      def check_constraints(table_name)
        @lock.synchronize do
          constraints = get_constraints_for_table(table_name)
          results = {
            total: constraints.size,
            enabled: constraints.count(&:enabled?),
            disabled: constraints.count { |c| !c.enabled? },
            constraints: constraints.map(&:to_hash)
          }
          results
        end
      end

      def enable_constraint(name)
        @lock.synchronize do
          constraint = get_constraint(name)
          constraint&.enable
        end
      end

      def disable_constraint(name)
        @lock.synchronize do
          constraint = get_constraint(name)
          constraint&.disable
        end
      end

      def stats
        @lock.synchronize do
          @stats.merge({
            total_constraints: @constraints.values.flatten.size,
            primary_keys: @constraints[:primary_key].size,
            foreign_keys: @constraints[:foreign_key].size,
            unique_constraints: @constraints[:unique].size,
            not_null_constraints: @constraints[:not_null].size,
            check_constraints: @constraints[:check].size,
            deferred_constraints: @deferred_constraints.size,
            cache_size: @constraint_cache.size
          })
        end
      end

      def clear
        @lock.synchronize do
          @constraints.each { |_, list| list.clear }
          @constraint_cache.clear
          @deferred_constraints.clear
          @stats = {
            validations: 0,
            valid_rows: 0,
            invalid_rows: 0,
            constraint_violations: 0,
            validation_time_ms: 0,
            total_validation_time_ms: 0,
            avg_validation_time_ms: 0
          }
        end
      end
    end
  end
end