# frozen_string_literal: true

module RubyDB
  module Functions
    # Function - Base class for all functions
    class Function
      attr_reader :name, :type, :description, :category
      attr_reader :min_args, :max_args, :return_type

      # Function types
      TYPE_SCALAR = :scalar
      TYPE_AGGREGATE = :aggregate
      TYPE_WINDOW = :window
      TYPE_SYSTEM = :system

      def initialize(name, type, options = {})
        @name = name
        @type = type
        @description = options[:description] || ""
        @category = options[:category] || :general
        @min_args = options[:min_args] || 0
        @max_args = options[:max_args] || -1  # -1 means unlimited
        @return_type = options[:return_type] || :text
        @deterministic = options[:deterministic] != false
        @strict = options[:strict] || false
        @immutable = options[:immutable] || false
        @parallel_safe = options[:parallel_safe] || true
        @registered_at = Time.now
      end

      def execute(args)
        raise NotImplementedError, "#{self.class} must implement #execute"
      end

      def validate_args(args)
        if args.size < @min_args
          raise ArgumentError, "Function '#{@name}' requires at least #{@min_args} arguments, got #{args.size}"
        end

        if @max_args >= 0 && args.size > @max_args
          raise ArgumentError, "Function '#{@name}' accepts at most #{@max_args} arguments, got #{args.size}"
        end

        true
      end

      def deterministic?
        @deterministic
      end

      def strict?
        @strict
      end

      def immutable?
        @immutable
      end

      def to_hash
        {
          name: @name,
          type: @type,
          description: @description,
          category: @category,
          min_args: @min_args,
          max_args: @max_args,
          return_type: @return_type,
          deterministic: @deterministic,
          strict: @strict,
          immutable: @immutable,
          parallel_safe: @parallel_safe,
          registered_at: @registered_at.iso8601
        }
      end

      def inspect
        "#<Function name=#{@name} type=#{@type} args=#{@min_args}..#{@max_args}>"
      end

      def to_s
        @name.to_s
      end
    end
  end
end