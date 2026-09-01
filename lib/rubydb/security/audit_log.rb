# frozen_string_literal: true

require "json"
require "fileutils"
require "time"

module RubyDB
  module Security
    # AuditLog - Logs security events
    class AuditLog
      attr_reader :stats

      # Event types
      EVENT_LOGIN = :login
      EVENT_LOGIN_SUCCESS = :login_success
      EVENT_LOGIN_FAILURE = :login_failure
      EVENT_LOGOUT = :logout
      EVENT_USER_CREATED = :user_created
      EVENT_USER_DELETED = :user_deleted
      EVENT_USER_UPDATED = :user_updated
      EVENT_ROLE_CREATED = :role_created
      EVENT_ROLE_DELETED = :role_deleted
      EVENT_ROLE_ASSIGNED = :role_assigned
      EVENT_ROLE_REVOKED = :role_revoked
      EVENT_PERMISSION_GRANTED = :permission_granted
      EVENT_PERMISSION_REVOKED = :permission_revoked
      EVENT_ACCESS_GRANTED = :access_granted
      EVENT_ACCESS_DENIED = :access_denied
      EVENT_QUERY_EXECUTED = :query_executed
      EVENT_SCHEMA_CHANGE = :schema_change
      EVENT_CONFIG_CHANGE = :config_change
      EVENT_SYSTEM_ERROR = :system_error
      EVENT_SECURITY_ALERT = :security_alert

      def initialize(config = {})
        @config = config
        @log_path = config[:log_path] || "audit.log"
        @batch_size = config[:batch_size] || 100
        @buffer = []
        @buffer_lock = Mutex.new
        @stats = {
          events_logged: 0,
          events_buffered: 0,
          events_flushed: 0,
          errors: 0,
          buffer_size: 0
        }
        @lock = Mutex.new

        # Create log directory
        FileUtils.mkdir_p(File.dirname(@log_path))

        # Start flush thread if async
        if config[:async] != false
          start_flush_thread
        end
      end

      def log(event_type, data = {})
        @lock.synchronize do
          entry = {
            timestamp: Time.now.iso8601,
            event: event_type,
            data: data,
            pid: Process.pid,
            thread: Thread.current.object_id,
            host: Socket.gethostname
          }

          @buffer << entry
          @stats[:events_logged] += 1
          @stats[:events_buffered] += 1
          @stats[:buffer_size] = @buffer.size

          flush if @buffer.size >= @batch_size

          entry
        end
      end

      def log_event(event_type, **data)
        log(event_type, data)
      end

      def flush
        @lock.synchronize do
          return if @buffer.empty?

          begin
            File.open(@log_path, "a") do |file|
              @buffer.each do |entry|
                file.puts(JSON.generate(entry))
              end
              file.flush
            end

            @stats[:events_flushed] += @buffer.size
            @stats[:events_buffered] = 0
            @buffer.clear
            @stats[:buffer_size] = 0

          rescue => e
            @stats[:errors] += 1
          end
        end
      end

      def query(conditions = {})
        @lock.synchronize do
          flush if @buffer.any?

          entries = []
          return entries unless File.exist?(@log_path)

          File.open(@log_path, "r") do |file|
            file.each_line do |line|
              begin
                entry = JSON.parse(line, symbolize_names: true)

                # Apply filters
                matched = true
                conditions.each do |key, value|
                  if entry[key] != value
                    matched = false
                    break
                  end
                end

                entries << entry if matched

              rescue JSON::ParserError
                # Skip malformed lines
              end
            end
          end

          entries
        end
      end

      def query_by_user(username, limit = 100)
        query({ user: username }).last(limit)
      end

      def query_by_event(event_type, limit = 100)
        query({ event: event_type }).last(limit)
      end

      def query_by_time(start_time, end_time, limit = 100)
        entries = query({})
        entries.select! do |entry|
          time = Time.parse(entry[:timestamp])
          time >= start_time && time <= end_time
        end
        entries.last(limit)
      end

      def clear
        @lock.synchronize do
          flush
          File.truncate(@log_path, 0) if File.exist?(@log_path)
          @stats[:events_logged] = 0
        end
      end

      def rotate(max_files = 10)
        @lock.synchronize do
          flush

          if File.size(@log_path) > @config[:max_size] || 10 * 1024 * 1024
            timestamp = Time.now.strftime("%Y%m%d_%H%M%S")
            archive_path = "#{@log_path}.#{timestamp}"

            # Move current log to archive
            FileUtils.mv(@log_path, archive_path)
            FileUtils.touch(@log_path)

            # Remove old archives
            archives = Dir.glob("#{@log_path}.*").sort
            while archives.size > max_files
              File.delete(archives.shift)
            end
          end
        end
      end

      def stats
        @lock.synchronize do
          @stats.merge({
            log_path: @log_path,
            buffer_size: @buffer.size,
            async: @flush_thread ? true : false
          })
        end
      end

      private

      def start_flush_thread
        @flush_thread = Thread.new do
          loop do
            sleep(5)
            begin
              flush
            rescue => e
              # Log error but continue
            end
          end
        end
      end
    end
  end
end