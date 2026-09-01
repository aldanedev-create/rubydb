# frozen_string_literal: true

require "socket"
require "thread"
require "time"
require "json"
require "fileutils"

require_relative "listener"
require_relative "connection"
require_relative "session"
require_relative "connection_pool"
require_relative "worker"
require_relative "request_handler"
require_relative "lifecycle"
require_relative "../protocol/protocol"
require_relative "../protocol/handshake"
require_relative "../storage/engine"
require_relative "../transactions/transaction_manager"

module RubyDB
  module Server
    # Server - Main database server
    class Server
      attr_reader :config, :engine, :listener, :connection_pool
      attr_reader :worker_pool, :request_handler, :lifecycle, :stats

      def initialize(config = {})
        @config = {
          host: config[:host] || "localhost",
          port: config[:port] || 7432,
          max_connections: config[:max_connections] || 100,
          min_workers: config[:min_workers] || 2,
          max_workers: config[:max_workers] || 20,
          worker_queue_size: config[:worker_queue_size] || 1000,
          read_timeout: config[:read_timeout] || 30,
          write_timeout: config[:write_timeout] || 30,
          idle_timeout: config[:idle_timeout] || 300,
          max_request_size: config[:max_request_size] || 10 * 1024 * 1024, # 10MB
          data_dir: config[:data_dir] || "data",
          log_dir: config[:log_dir] || "log",
          pid_file: config[:pid_file] || "rubydb.pid",
          daemonize: config[:daemonize] || false,
          authentication: config[:authentication] || { method: "none" },
          ssl: config[:ssl] || { enabled: false }
        }.merge(config)

        @stats = {
          connections_total: 0,
          connections_active: 0,
          connections_rejected: 0,
          requests_processed: 0,
          requests_failed: 0,
          bytes_received: 0,
          bytes_sent: 0,
          started_at: nil,
          uptime_seconds: 0,
          last_activity: nil
        }

        @lock = Mutex.new
        @running = false
        @shutdown = false

        # Setup directories
        setup_directories

        # Initialize components
        initialize_components
      end

      def start
        @lock.synchronize do
          return if @running

          @running = true
          @shutdown = false
          @stats[:started_at] = Time.now

          # Daemonize if configured
          daemonize if @config[:daemonize]

          # Write PID file
          write_pid_file

          # Start components
          @listener.start
          @connection_pool.start
          @worker_pool.start
          @lifecycle.start

          puts "RubyDB Server v#{RubyDB::VERSION} started on #{@config[:host]}:#{@config[:port]}"
          puts "Data directory: #{@config[:data_dir]}"
          puts "Max connections: #{@config[:max_connections]}"

          # Update stats thread
          start_stats_thread

          true
        end
      end

      def stop
        @lock.synchronize do
          return unless @running

          @shutdown = true
          puts "Shutting down RubyDB Server..."

          # Stop accepting new connections
          @listener.stop

          # Close all connections
          @connection_pool.close_all

          # Stop workers
          @worker_pool.stop

          # Stop lifecycle
          @lifecycle.stop

          # Remove PID file
          remove_pid_file

          @running = false

          puts "RubyDB Server stopped"
          true
        end
      end

      def restart
        stop
        sleep(1)
        start
      end

      def running?
        @running
      end

      def stats
        @lock.synchronize do
          elapsed = @stats[:started_at] ? (Time.now - @stats[:started_at]).to_i : 0
          @stats[:uptime_seconds] = elapsed

          @stats.merge({
            engine_stats: @engine&.stats || {},
            connection_pool_stats: @connection_pool&.stats || {},
            worker_pool_stats: @worker_pool&.stats || {},
            memory_usage: get_memory_usage,
            pid: Process.pid
          })
        end
      end

      private

      def initialize_components
        # Initialize storage engine
        db_path = File.join(@config[:data_dir], "rubydb.rdb")
        @engine = Storage::Engine.new(db_path, @config)

        # Initialize transaction manager
        @transaction_manager = Transactions::TransactionManager.new(@engine, @config)

        # Initialize protocol
        @protocol = Protocol::Protocol.new(
          format: :json,
          compression: true,
          server_info: {
            version: RubyDB::VERSION,
            pid: Process.pid,
            started_at: Time.now.iso8601
          }
        )

        # Initialize connection pool
        @connection_pool = ConnectionPool.new(@config, @protocol)

        # Initialize worker pool
        @worker_pool = WorkerPool.new(@config, @engine, @transaction_manager)

        # Initialize request handler
        @request_handler = RequestHandler.new(@engine, @transaction_manager, @config)

        # Initialize listener
        @listener = Listener.new(@config, @connection_pool, @worker_pool)

        # Initialize lifecycle
        @lifecycle = Lifecycle.new(self, @config)
      end

      def setup_directories
        [:data_dir, :log_dir].each do |dir|
          path = @config[dir]
          FileUtils.mkdir_p(path) unless Dir.exist?(path)
        end
      end

      def daemonize
        return unless @config[:daemonize]

        Process.daemon(true, true)
        $stdout.reopen(File.join(@config[:log_dir], "rubydb.out"), "a")
        $stderr.reopen(File.join(@config[:log_dir], "rubydb.err"), "a")
      end

      def write_pid_file
        File.write(@config[:pid_file], Process.pid.to_s)
      end

      def remove_pid_file
        File.delete(@config[:pid_file]) if File.exist?(@config[:pid_file])
      end

      def start_stats_thread
        Thread.new do
          while @running
            sleep(10)
            update_stats
          end
        end
      end

      def update_stats
        @lock.synchronize do
          @stats[:connections_active] = @connection_pool&.active_count || 0
          @stats[:connections_total] = @connection_pool&.total_connections || 0
          @stats[:requests_processed] = @request_handler&.stats&.dig(:requests_processed) || 0
        end
      end

      def get_memory_usage
        # Get memory usage in MB
        if File.exist?("/proc/self/status")
          File.read("/proc/self/status").each_line do |line|
            if line.start_with?("VmRSS:")
              return line.split[1].to_i / 1024
            end
          end
        end

        # Fallback - run ps command
        begin
          output = `ps -o rss= -p #{Process.pid}`
          return output.strip.to_i / 1024 if output && !output.empty?
        rescue
          # Ignore
        end

        0
      rescue
        0
      end
    end
  end
end