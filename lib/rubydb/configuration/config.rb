# frozen_string_literal: true

require "singleton"

module RubyDB
  module Configuration
    # Config - Main configuration access point
    class Config
      include Singleton

      attr_reader :environment, :parser, :validation

      def initialize
        @environment = Environment.new
        @parser = Parser.new
        @validation = Validation.new
        @loaded = false
        @config_path = nil
        @config = {}
        @lock = Mutex.new
      end

      def self.load(config_path = nil)
        instance.load(config_path)
      end

      def self.get(path)
        instance.get(path)
      end

      def self.set(path, value)
        instance.set(path, value)
      end

      def self.[](key)
        instance[key]
      end

      def self.[]=(key, value)
        instance[key] = value
      end

      def self.to_hash
        instance.to_hash
      end

      def self.valid?
        instance.valid?
      end

      def self.errors
        instance.errors
      end

      def self.warnings
        instance.warnings
      end

      def self.environment
        instance.environment.name
      end

      def self.environment=(env)
        instance.environment = env
      end

      def load(config_path = nil)
        @lock.synchronize do
          @config_path = config_path
          @config = @environment.load(config_path)
          @loaded = true
          @config
        end
      end

      def reload
        @lock.synchronize do
          @loaded = false
          load(@config_path)
        end
      end

      def get(path)
        ensure_loaded
        @environment.get(path)
      end

      def set(path, value)
        ensure_loaded
        @environment.set(path, value)
      end

      def [](key)
        ensure_loaded
        @environment[key]
      end

      def []=(key, value)
        ensure_loaded
        @environment[key] = value
      end

      def to_hash
        ensure_loaded
        @environment.to_hash
      end

      def valid?
        ensure_loaded
        @environment.valid?
      end

      def errors
        ensure_loaded
        @environment.errors
      end

      def warnings
        ensure_loaded
        @environment.warnings
      end

      def environment=(env)
        @lock.synchronize do
          @environment = Environment.new(env)
          @loaded = false
        end
      end

      def environment
        @environment.name
      end

      def production?
        @environment.production?
      end

      def development?
        @environment.development?
      end

      def test?
        @environment.test?
      end

      def staging?
        @environment.staging?
      end

      def stats
        {
          loaded: @loaded,
          config_path: @config_path,
          environment: environment,
          config_keys: @config.keys.size,
          errors: errors.size,
          warnings: warnings.size,
          valid: valid?
        }
      end

      private

      def ensure_loaded
        load unless @loaded
      end
    end
  end
end