# frozen_string_literal: true

module RubyDB
  module Configuration
    # Defaults - Default configuration values
    class Defaults
      DEFAULTS = {
        # Server settings
        server: {
          host: "localhost",
          port: 7432,
          max_connections: 100,
          min_workers: 2,
          max_workers: 20,
          worker_queue_size: 1000,
          read_timeout: 30,
          write_timeout: 30,
          idle_timeout: 300,
          max_request_size: 10 * 1024 * 1024, # 10MB
          daemonize: false,
          pid_file: "rubydb.pid",
          log_level: "info"
        },

        # Storage settings
        storage: {
          data_dir: "data",
          page_size: 8192,
          buffer_pool_size: 1000,
          wal_enabled: true,
          wal_dir: "wal",
          wal_segment_size: 16 * 1024 * 1024, # 16MB
          wal_keep_segments: 100,
          fsync: true,
          compress: false
        },

        # Database settings
        database: {
          name: "rubydb",
          encoding: "UTF8",
          locale: "en_US.UTF-8",
          default_isolation_level: "read_committed",
          max_connections: 100,
          statement_timeout: 30,
          idle_in_transaction_timeout: 60
        },

        # Authentication settings
        auth: {
          method: "password",
          session_timeout: 3600,
          max_attempts: 5,
          lockout_duration: 900,
          password_algorithm: "sha256",
          password_iterations: 10000,
          salt_length: 16
        },

        # SSL settings
        ssl: {
          enabled: false,
          cert_file: nil,
          key_file: nil,
          ca_file: nil,
          verify_peer: false
        },

        # Replication settings
        replication: {
          enabled: false,
          role: "standalone",
          primary_host: nil,
          primary_port: 7433,
          sync_mode: "async",
          sync_replicas: 1,
          replication_port: 7434,
          max_replicas: 10
        },

        # Backup settings
        backup: {
          backup_dir: "backups",
          retention_days: 30,
          max_backups: 10,
          verify_after_backup: true,
          include_wal: true,
          include_schema: true,
          compress: true,
          compression_level: 6
        },

        # Logging settings
        logging: {
          log_dir: "log",
          log_file: "rubydb.log",
          log_level: "info",
          log_format: "json",
          rotate_size: 10 * 1024 * 1024, # 10MB
          rotate_count: 10,
          audit_log: true,
          slow_query_threshold: 1000 # ms
        },

        # Monitoring settings
        monitoring: {
          enabled: true,
          metrics_interval: 10,
          health_check_interval: 30,
          stats_collector: true,
          prometheus: false,
          prometheus_port: 9090
        },

        # Development settings
        development: {
          auto_migrate: true,
          seed_data: false,
          debug: false,
          profile: false,
          fake_data: false
        }
      }

      def self.all
        DEFAULTS
      end

      def self.get(path)
        parts = path.to_s.split(".")
        value = DEFAULTS
        parts.each do |part|
          value = value[part.to_sym]
          return nil if value.nil?
        end
        value
      end

      def self.set(path, value)
        parts = path.to_s.split(".")
        target = DEFAULTS
        parts[0...-1].each do |part|
          target = target[part.to_sym]
          return false if target.nil?
        end
        target[parts.last.to_sym] = value
        true
      end

      def self.merge(overrides)
        deep_merge(DEFAULTS, overrides)
      end

      def self.deep_merge(hash1, hash2)
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

      def self.to_hash
        DEFAULTS
      end

      def self.keys
        DEFAULTS.keys
      end

      def self.has_key?(key)
        DEFAULTS.key?(key)
      end
    end
  end
end