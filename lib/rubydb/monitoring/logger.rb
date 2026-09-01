# frozen_string_literal: true

require "time"
require "json"
require "fileutils"

module RubyDB
  module Monitoring
    # Logger - Structured logging
    class Logger
      attr_reader :stats

      # Log levels
      LEVEL_DEBUG = 0
      LEVEL_INFO = 1
      LEVEL_WARN = 2
      LEVEL_ERROR = 3
      LEVEL_FATAL = 4

      LEVEL_NAMES = {
        0 => "DEBUG",
        1 => "INFO",
        2 => "WARN",
        3 => "ERROR",
        4 => "FATAL"
      }

      def initialize(config = {})
        @config = config
        @log_dir = config[:log_dir] || "log"
        @log_file = config[:log_file] || "rubydb.log"
        @level = config[:level] || LEVEL_INFO
        @format = config[:format] || :json
        @max_size = config[:max_size] || 10 * 1024 * 1024
        @max_files = config[:max_files] || 10
        @sync = config[:sync] || false
        @stats = {
          logs_written: 0,
          logs_failed: 0,
          log_rotations: 0,
          buffer_size: 0
        }
        @buffer = []
        @buffer_size = config[:buffer_size] || 100
        @lock = Mutex.new
        @file = nil

        FileUtils.mkdir_p(@log_dir)
        open_log_file
        start_flush_thread if config[:async] != false
      end

      def debug(message, data = {})
        log(LEVEL_DEBUG, message, data)
      end

      def info(message, data = {})
        log(LEVEL_INFO, message, data)
      end

      def warn(message, data = {})
        log(LEVEL_WARN, message, data)
      end

      def error(message, data = {})
        log(LEVEL_ERROR, message, data)
      end

      def fatal(message, data = {})
        log(LEVEL_FATAL, message, data)
      end

      def log(level, message, data = {})
        return if level < @level

        @lock.synchronize do
          entry = {
            timestamp: Time.now.iso8601,
            level: LEVEL_NAMES[level],
            message: message,
            data: data,
            pid: Process.pid,
            thread: Thread.current.object_id
          }

          @buffer << entry
          @stats[:buffer_size] = @buffer.size

          if @buffer.size >= @buffer_size
            flush
          end
        end
      end

      def flush
        @lock.synchronize do
          return if @buffer.empty?

          begin
            rotate_log if File.size(@log_path) > @max_size

            File.open(@log_path, "a") do |file|
              @buffer.each do |entry|
                line = format_entry(entry)
                file.puts(line)
              end
              file.flush if @sync
            end

            @stats[:logs_written] += @buffer.size
            @buffer.clear
            @stats[:buffer_size] = 0

          rescue => e
            @stats[:logs_failed] += 1
          end
        end
      end

      def close
        flush
        @file.close if @file
      end

      def level=(level)
        @level = level
      end

      def level
        @level
      end

      def stats
        @lock.synchronize do
          @stats.merge({
            level: LEVEL_NAMES[@level],
            format: @format,
            buffer_size: @buffer.size,
            log_path: @log_path,
            sync: @sync
          })
        end
      end

      private

      def open_log_file
        @log_path = File.join(@log_dir, @log_file)
        @file = File.open(@log_path, "a")
        @file.sync = @sync
      end

      def rotate_log
        @file.close if @file

        timestamp = Time.now.strftime("%Y%m%d_%H%M%S")
        archive_path = "#{@log_path}.#{timestamp}"
        FileUtils.mv(@log_path, archive_path)

        # Remove old archives
        archives = Dir.glob("#{@log_path}.*").sort
        while archives.size > @max_files - 1
          File.delete(archives.shift)
        end

        open_log_file
        @stats[:log_rotations] += 1
      end

      def format_entry(entry)
        case @format
        when :json
          JSON.generate(entry)
        else
          "[#{entry[:timestamp]}] #{entry[:level]} [#{entry[:pid]}]: #{entry[:message]}"
        end
      end

      def start_flush_thread
        Thread.new do
          loop do
            sleep(1)
            begin
              flush
            rescue => e
              # Continue running
            end
          end
        end
      end
    end
  end
end