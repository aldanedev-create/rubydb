# frozen_string_literal: true

require "yaml"
require "json"
require "erb"

module RubyDB
  module Configuration
    # Parser - Parses configuration from various sources
    class Parser
      attr_reader :errors, :warnings

      def initialize
        @errors = []
        @warnings = []
      end

      def parse_file(file_path)
        return {} unless File.exist?(file_path)

        content = File.read(file_path)
        parse_string(content, file_path)
      end

      def parse_string(content, source = nil)
        @errors = []
        @warnings = []

        # Process ERB if present
        if content.include?("<%")
          content = ERB.new(content).result
        end

        # Try YAML first
        begin
          config = YAML.safe_load(content, symbolize_names: true)
          return config if config.is_a?(Hash)
        rescue Psych::SyntaxError => e
          @warnings << "YAML parsing failed, trying JSON: #{e.message}"
        end

        # Try JSON
        begin
          config = JSON.parse(content, symbolize_names: true)
          return config if config.is_a?(Hash)
        rescue JSON::ParserError => e
          @errors << "Failed to parse configuration: #{e.message}"
        end

        {}
      end

      def parse_env(prefix = "RUBYDB_")
        config = {}

        ENV.each do |key, value|
          next unless key.start_with?(prefix)

          # Convert RUBYDB_SERVER_HOST to server.host
          path = key[prefix.length..-1].downcase.split("_").join(".")
          set_nested_value(config, path, parse_value(value))
        end

        config
      end

      def parse_args(args)
        config = {}
        i = 0

        while i < args.length
          arg = args[i]

          if arg.start_with?("--")
            key = arg[2..-1]
            value = args[i + 1] if i + 1 < args.length

            if value && !value.start_with?("--")
              set_nested_value(config, key, parse_value(value))
              i += 2
            else
              set_nested_value(config, key, true)
              i += 1
            end
          elsif arg.start_with?("-")
            key = arg[1..-1]
            value = args[i + 1] if i + 1 < args.length

            if value && !value.start_with?("-")
              set_nested_value(config, key, parse_value(value))
              i += 2
            else
              set_nested_value(config, key, true)
              i += 1
            end
          else
            i += 1
          end
        end

        config
      end

      def parse_url(url)
        config = {}

        return config unless url =~ /^rubydb:\/\/([^@]+@)?([^:]+):([0-9]+)\/(.+)$/

        user_pass = $1
        host = $2
        port = $3.to_i
        database = $4

        config[:server] ||= {}
        config[:server][:host] = host
        config[:server][:port] = port

        config[:database] ||= {}
        config[:database][:name] = database

        if user_pass
          user, pass = user_pass.chomp("@").split(":")
          config[:auth] ||= {}
          config[:auth][:username] = user
          config[:auth][:password] = pass if pass
        end

        config
      end

      def merge_configs(*configs)
        result = {}
        configs.compact.each do |config|
          result = deep_merge(result, config)
        end
        result
      end

      private

      def parse_value(value)
        return true if value == "true"
        return false if value == "false"
        return nil if value == "null" || value == "nil"

        if value =~ /^\d+$/
          return value.to_i
        end

        if value =~ /^\d+\.\d+$/
          return value.to_f
        end

        value
      end

      def set_nested_value(hash, path, value)
        keys = path.split(".")
        target = hash

        keys[0...-1].each do |key|
          key = key.to_sym
          target[key] ||= {}
          target = target[key]
        end

        target[keys.last.to_sym] = value
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