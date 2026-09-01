# frozen_string_literal: true

module RubyDB
  module Functions
    # ScalarFunction - Base class for scalar functions (return single value)
    class ScalarFunction < Function
      def initialize(name, options = {})
        super(name, TYPE_SCALAR, options)
        @cache_enabled = options[:cache] || false
        @cache = {}
        @cache_size = options[:cache_size] || 1000
      end

      def execute(args)
        validate_args(args)

        # Check cache if enabled
        if @cache_enabled
          cache_key = args.map(&:to_s).join("||")
          if @cache.key?(cache_key)
            return @cache[cache_key]
          end
        end

        result = execute_scalar(args)

        # Cache result if enabled
        if @cache_enabled && @cache.size < @cache_size
          cache_key = args.map(&:to_s).join("||")
          @cache[cache_key] = result
        end

        result
      end

      def execute_scalar(args)
        raise NotImplementedError, "#{self.class} must implement #execute_scalar"
      end

      def clear_cache
        @cache.clear
      end

      def to_hash
        super.merge({
          cache_enabled: @cache_enabled,
          cache_size: @cache.size
        })
      end
    end
  end
end