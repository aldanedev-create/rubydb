# frozen_string_literal: true

require "optparse"

module RubyDB
  module CLI
    module Commands
      # Start - Start the database server
      class Start
        def initialize(output, formatter)
          @output = output
          @formatter = formatter
        end

        def execute(args, options)
          parser = OptionParser.new do |opts|
            opts.banner = "Usage: rubydb start [options]"
            opts.on("-d", "--daemon", "Run as daemon") do
              options[:daemon] = true
            end
            opts.on("-p", "--port PORT", Integer, "Server port") do |port|
              options[:port] = port
            end
            opts.on("--data-dir DIR", "Database data directory") { |dir| options[:data_dir] = dir }
            opts.on("--log-dir DIR", "Server log directory") { |dir| options[:log_dir] = dir }
            opts.on("-H", "--host HOST", "Server host") do |host|
              options[:host] = host
            end
            opts.on("--pid-file FILE", "PID file") do |file|
              options[:pid_file] = file
            end
            opts.on("-h", "--help", "Show help") do
              @output.puts opts
              exit(0)
            end
          end

          parser.parse!(args)

          configured = load_runtime_config(options)
          server_config = configured[:server] || {}

          server_options = {
            host: options[:host] || server_config[:host] || "localhost",
            port: options[:port] || server_config[:port] || 7432,
            data_dir: options[:data_dir] || configured.dig(:storage, :data_dir) || "data",
            log_dir: options[:log_dir] || configured.dig(:logging, :log_dir) || "log",
            pid_file: options[:pid_file] || server_config[:pid_file] || "rubydb.pid",
            daemonize: options[:daemon] == true || server_config[:daemonize] == true,
            max_connections: server_config[:max_connections],
            min_workers: server_config[:min_workers],
            max_workers: server_config[:max_workers],
            read_timeout: server_config[:read_timeout],
            write_timeout: server_config[:write_timeout],
            idle_timeout: server_config[:idle_timeout],
            max_request_size: server_config[:max_request_size],
            authentication: (options[:config] || options[:env].to_s == "production") ? configured[:auth] : { method: "none" },
            ssl: configured[:ssl] || { enabled: false }
          }.compact
          server = RubyDB::Server::Server.new(server_options)
          server.start
          @output.success("RubyDB server started on #{server.config[:host]}:#{server.config[:port]}")
          return 0 if options[:daemon]

          trap("INT") { server.stop; exit(0) }
          trap("TERM") { server.stop; exit(0) }
          sleep
        end

        private

        def load_runtime_config(options)
          RubyDB::Configuration::Config.environment = options[:env] if options[:env]
          config = RubyDB::Configuration::Config.load(options[:config])
          raise "Invalid configuration: #{RubyDB::Configuration::Config.errors.join('; ')}" unless config && RubyDB::Configuration::Config.valid?

          config
        end
      end
    end
  end
end
