# frozen_string_literal: true

module RubyDB
  module Catalog
    # Sequence - generates sequential numeric values
    class Sequence
      attr_reader :name, :start_value, :increment, :min_value, :max_value, :cycle
      attr_accessor :current_value

      def initialize(name, options = {})
        @name = name
        @start_value = options[:start] || 1
        @increment = options[:increment] || 1
        @min_value = options[:min_value] || 1
        @max_value = options[:max_value] || 9_223_372_036_854_775_807
        @cycle = options[:cycle] || false
        @current_value = @start_value - @increment
        @created_at = Time.now
        @modified_at = Time.now
      end

      def next_value
        @current_value += @increment

        if @current_value > @max_value
          if @cycle
            @current_value = @min_value
          else
            raise DatabaseError, "Sequence '#{@name}' exceeded max value #{@max_value}"
          end
        end

        @modified_at = Time.now
        @current_value
      end

      def reset
        @current_value = @start_value - @increment
        @modified_at = Time.now
      end

      def current
        @current_value
      end

      def to_s
        "#{@name} (current: #{@current_value})"
      end

      def inspect
        "#<Sequence name=#{@name} start=#{@start_value} current=#{@current_value} increment=#{@increment}>"
      end

      # --- Serialization ---

      def serialize
        {
          name: @name,
          start_value: @start_value,
          increment: @increment,
          min_value: @min_value,
          max_value: @max_value,
          cycle: @cycle,
          current_value: @current_value,
          created_at: @created_at.iso8601,
          modified_at: @modified_at.iso8601
        }
      end

      def self.deserialize(data)
        seq = new(
          data[:name],
          start: data[:start_value] || 1,
          increment: data[:increment] || 1,
          min_value: data[:min_value] || 1,
          max_value: data[:max_value] || 9_223_372_036_854_775_807,
          cycle: data[:cycle] || false
        )
        seq.current_value = data[:current_value] if data[:current_value]
        seq.send(:created_at=, Time.parse(data[:created_at])) if data[:created_at]
        seq.send(:modified_at=, Time.parse(data[:modified_at])) if data[:modified_at]
        seq
      end

      protected

      attr_writer :created_at, :modified_at
    end
  end
end
