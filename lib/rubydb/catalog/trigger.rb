# frozen_string_literal: true

module RubyDB
  module Catalog
    # Trigger - executes a function on table events
    class Trigger
      attr_reader :name, :event, :table_name, :definition
      attr_reader :timing, :condition, :function_name
      attr_accessor :enabled

      def initialize(name, event, table_name, definition, options = {})
        @name = name
        @event = event  # :insert, :update, :delete, or array of these
        @table_name = table_name
        @definition = definition
        @timing = options[:timing] || :after  # :before, :after, :instead_of
        @condition = options[:condition]
        @function_name = options[:function_name]
        @enabled = options.fetch(:enabled, true)
        @created_at = Time.now
        @modified_at = Time.now
      end

      def event_types
        @event.is_a?(Array) ? @event : [@event]
      end

      def on_insert?
        event_types.include?(:insert)
      end

      def on_update?
        event_types.include?(:update)
      end

      def on_delete?
        event_types.include?(:delete)
      end

      def before?
        @timing == :before
      end

      def after?
        @timing == :after
      end

      def instead_of?
        @timing == :instead_of
      end

      def enabled?
        @enabled
      end

      def to_s
        "TRIGGER #{@name} #{@timing} #{@event} ON #{@table_name}"
      end

      def inspect
        "#<Trigger name=#{@name} event=#{@event} table=#{@table_name} timing=#{@timing} enabled=#{@enabled}>"
      end

      # --- Serialization ---

      def serialize
        {
          name: @name,
          event: @event,
          table_name: @table_name,
          definition: @definition,
          timing: @timing,
          condition: @condition,
          function_name: @function_name,
          enabled: @enabled,
          created_at: @created_at.iso8601,
          modified_at: @modified_at.iso8601
        }
      end

      def self.deserialize(data)
        trigger = new(
          data[:name],
          data[:event],
          data[:table_name],
          data[:definition],
          timing: data[:timing] || :after,
          condition: data[:condition],
          function_name: data[:function_name],
          enabled: data[:enabled] != false
        )
        trigger.created_at = Time.parse(data[:created_at]) if data[:created_at]
        trigger.modified_at = Time.parse(data[:modified_at]) if data[:modified_at]
        trigger
      end

      protected

      attr_writer :created_at, :modified_at
    end
  end
end