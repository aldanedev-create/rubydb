# frozen_string_literal: true

module RubyDB
  module Configuration
    # Validation - Configuration validation
    class Validation
      attr_reader :errors, :warnings

      # Validation rules
      RULES = {
        "server.host" => { type: :string, required: true },
        "server.port" => { type: :integer, required: true, min: 1, max: 65535 },
        "server.max_connections" => { type: :integer, required: true, min: 1, max: 10000 },
        "server.min_workers" => { type: :integer, required: true, min: 1 },
        "server.max_workers" => { type: :integer, required: true, min: 1 },
        "server.worker_queue_size" => { type: :integer, required: true, min: 1 },
        "server.read_timeout" => { type: :integer, required: true, min: 1 },
        "server.write_timeout" => { type: :integer, required: true, min: 1 },
        "server.idle_timeout" => { type: :integer, required: true, min: 1 },
        "server.max_request_size" => { type: :integer, required: true, min: 1024 },
        "server.daemonize" => { type: :boolean, required: true },
        "server.log_level" => { type: :string, required: true, enum: ["debug", "info", "warn", "error", "fatal"] },

        "storage.data_dir" => { type: :string, required: true },
        "storage.page_size" => { type: :integer, required: true, enum: [4096, 8192, 16384, 32768] },
        "storage.buffer_pool_size" => { type: :integer, required: true, min: 10 },
        "storage.wal_enabled" => { type: :boolean, required: true },
        "storage.wal_dir" => { type: :string, required: true },
        "storage.wal_segment_size" => { type: :integer, required: true, min: 1024 * 1024 },
        "storage.wal_keep_segments" => { type: :integer, required: true, min: 1 },
        "storage.fsync" => { type: :boolean, required: true },

        "database.name" => { type: :string, required: true },
        "database.encoding" => { type: :string, required: true },
        "database.locale" => { type: :string, required: true },
        "database.default_isolation_level" => { type: :string, required: true, enum: ["read_uncommitted", "read_committed", "repeatable_read", "serializable"] },
        "database.max_connections" => { type: :integer, required: true, min: 1 },
        "database.statement_timeout" => { type: :integer, required: true, min: 1 },
        "database.idle_in_transaction_timeout" => { type: :integer, required: true, min: 1 },

        "auth.method" => { type: :string, required: true, enum: ["none", "password", "md5", "scram_sha256", "token", "certificate"] },
        "auth.session_timeout" => { type: :integer, required: true, min: 60 },
        "auth.max_attempts" => { type: :integer, required: true, min: 1 },
        "auth.lockout_duration" => { type: :integer, required: true, min: 1 },
        "auth.password_algorithm" => { type: :string, required: true, enum: ["sha256", "sha512", "bcrypt", "pbkdf2", "argon2"] },
        "auth.password_iterations" => { type: :integer, required: true, min: 1000 },
        "auth.salt_length" => { type: :integer, required: true, min: 8 },

        "ssl.enabled" => { type: :boolean, required: true },

        "replication.enabled" => { type: :boolean, required: true },
        "replication.role" => { type: :string, required: true, enum: ["standalone", "primary", "replica", "standby"] },
        "replication.sync_mode" => { type: :string, required: true, enum: ["async", "sync", "quorum"] },
        "replication.sync_replicas" => { type: :integer, required: true, min: 0 },
        "replication.replication_port" => { type: :integer, required: true, min: 1, max: 65535 },
        "replication.max_replicas" => { type: :integer, required: true, min: 0 },

        "backup.backup_dir" => { type: :string, required: true },
        "backup.retention_days" => { type: :integer, required: true, min: 1 },
        "backup.max_backups" => { type: :integer, required: true, min: 1 },
        "backup.verify_after_backup" => { type: :boolean, required: true },
        "backup.include_wal" => { type: :boolean, required: true },
        "backup.include_schema" => { type: :boolean, required: true },
        "backup.compress" => { type: :boolean, required: true },
        "backup.compression_level" => { type: :integer, required: true, min: 1, max: 9 },

        "logging.log_dir" => { type: :string, required: true },
        "logging.log_level" => { type: :string, required: true, enum: ["debug", "info", "warn", "error", "fatal"] },
        "logging.log_format" => { type: :string, required: true, enum: ["json", "text"] },
        "logging.rotate_size" => { type: :integer, required: true, min: 1024 * 1024 },
        "logging.rotate_count" => { type: :integer, required: true, min: 1 },
        "logging.audit_log" => { type: :boolean, required: true },
        "logging.slow_query_threshold" => { type: :integer, required: true, min: 0 },

        "monitoring.enabled" => { type: :boolean, required: true },
        "monitoring.metrics_interval" => { type: :integer, required: true, min: 1 },
        "monitoring.health_check_interval" => { type: :integer, required: true, min: 1 },
        "monitoring.stats_collector" => { type: :boolean, required: true },
        "monitoring.prometheus" => { type: :boolean, required: true },
        "monitoring.prometheus_port" => { type: :integer, required: true, min: 1, max: 65535 }
      }

      def initialize
        @errors = []
        @warnings = []
        @valid = false
      end

      def validate(config)
        @errors = []
        @warnings = []
        @valid = true

        RULES.each do |path, rules|
          value = get_value(config, path)
          validate_value(path, value, rules)
        end

        # Cross-field validations
        validate_cross_fields(config)

        @valid = @errors.empty?
        @valid
      end

      def valid?
        @valid
      end

      def errors
        @errors.dup
      end

      def warnings
        @warnings.dup
      end

      private

      def get_value(config, path)
        parts = path.split(".")
        value = config
        parts.each do |part|
          return nil unless value.is_a?(Hash) && value.key?(part.to_sym)
          value = value[part.to_sym]
        end
        value
      end

      def validate_value(path, value, rules)
        # Check required
        if rules[:required] && value.nil?
          @errors << "#{path} is required"
          return
        end

        return if value.nil?

        # Check type
        case rules[:type]
        when :string
          unless value.is_a?(String)
            @errors << "#{path} must be a string"
            return
          end
        when :integer
          unless value.is_a?(Integer)
            @errors << "#{path} must be an integer"
            return
          end
        when :boolean
          unless [true, false].include?(value)
            @errors << "#{path} must be a boolean"
            return
          end
        end

        # Check min/max
        if rules[:min] && value < rules[:min]
          @errors << "#{path} must be at least #{rules[:min]}"
        end

        if rules[:max] && value > rules[:max]
          @errors << "#{path} must be at most #{rules[:max]}"
        end

        # Check enum
        if rules[:enum] && !rules[:enum].include?(value)
          @errors << "#{path} must be one of: #{rules[:enum].join(', ')}"
        end

        # Check format
        if rules[:format] && value !~ rules[:format]
          @errors << "#{path} has invalid format"
        end
      end

      def validate_cross_fields(config)
        # Server validation
        if config[:server]
          if config[:server][:min_workers] > config[:server][:max_workers]
            @errors << "server.min_workers must be less than or equal to server.max_workers"
          end

          if config[:server][:max_connections] < config[:server][:max_workers]
            @warnings << "server.max_connections should be greater than server.max_workers"
          end
        end

        # Storage validation
        if config[:storage]
          if config[:storage][:page_size] && config[:storage][:page_size] < 4096
            @warnings << "storage.page_size is unusually small (recommended: 8192)"
          end

          if config[:storage][:buffer_pool_size] && config[:storage][:buffer_pool_size] < 10
            @errors << "storage.buffer_pool_size must be at least 10"
          end
        end

        # Replication validation
        if config[:replication] && config[:replication][:enabled]
          if config[:replication][:role] == "replica" && config[:replication][:primary_host].nil?
            @errors << "replication.primary_host is required for replica role"
          end

          if config[:replication][:role] == "primary" && config[:replication][:sync_replicas] > config[:replication][:max_replicas]
            @warnings << "replication.sync_replicas should not exceed replication.max_replicas"
          end
        end

        # SSL validation
        if config[:ssl] && config[:ssl][:enabled]
          if config[:ssl][:cert_file].nil? || config[:ssl][:key_file].nil?
            @errors << "ssl.cert_file and ssl.key_file are required when SSL is enabled"
          end
        end
      end
    end
  end
end