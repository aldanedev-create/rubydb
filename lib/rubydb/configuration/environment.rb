# frozen_string_literal: true

module RubyDB
  module Configuration
    # Environment - Manages environment-specific configuration
    class Environment
      attr_reader :name, :config, :defaults

      ENVIRONMENTS = [:development, :test, :production, :staging]

      def initialize(name = nil)
        @name = name || ENV["RUBYDB_ENV"] || "development"
        @name = @name.to_sym
        @defaults = Defaults.all
        @config = {}
        @loaded = false
        @parser = Parser.new
        @validation = Validation.new
      end

      def load(config_path = nil)
        @config = {}

        # Load defaults
        @config = deep_merge(@config, @defaults)

        # Load base config
        if config_path
          base_config = @parser.parse_file(config_path)
          @config = deep_merge(@config, base_config)
        end

        # Load environment-specific config
        env_config_path = config_path ? "#{config_path}.#{@name}" : nil
        if env_config_path && File.exist?(env_config_path)
          env_config = @parser.parse_file(env_config_path)
          @config = deep_merge(@config, env_config)
        end

        # Load environment variables
        env_config = @parser.parse_env
        @config = deep_merge(@config, env_config)

        # Validate
        @validation.validate(@config)

        @loaded = true
        @config
      end

      def reload
        @loaded = false
        load
      end

      def [](key)
        ensure_loaded
        get_value(@config, key.to_s)
      end

      def []=(key, value)
        ensure_loaded
        set_value(@config, key.to_s, value)
      end

      def get(path)
        ensure_loaded
        get_value(@config, path.to_s)
      end

      def set(path, value)
        ensure_loaded
        set_value(@config, path.to_s, value)
      end

      def to_hash
        ensure_loaded
        @config.dup
      end

      def valid?
        ensure_loaded
        @validation.valid?
      end

      def errors
        ensure_loaded
        @validation.errors
      end

      def warnings
        ensure_loaded
        @validation.warnings
      end

      def production?
        @name == :production
      end

      def development?
        @name == :development
      end

      def test?
        @name == :test
      end

      def staging?
        @name == :staging
      end

      private

      def ensure_loaded
        load unless @loaded
      end

      def get_value(hash, path)
        parts = path.split(".")
        value = hash
        parts.each do |part|
          return nil unless value.is_a?(Hash) && value.key?(part.to_sym)
          value = value[part.to_sym]
        end
        value
      end

      def set_value(hash, path, value)
        parts = path.split(".")
        target = hash
        parts[0...-1].each do |part|
          part = part.to_sym
          target[part] ||= {}
          target = target[part]
        end
        target[parts.last.to_sym] = value
      end

      def deep_merge(hash1, hash2)
        result = hash1.dup
        hash2.each do |key, value|
          if value.is_a?(Hash) && result[key].is_a?(Hash)
            result[key] = deep_merge(result[key], value)
          else
            result[key] = value
          end
        end
        result
      end
    end
  end
end