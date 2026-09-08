# frozen_string_literal: true

require "monitor"
require "fileutils"

module RubyDB
  module Storage
    # Owns an embedded database path for exactly one engine process. RubyDB's
    # page cache, metadata sidecars, WAL and MVCC files are coordinated inside
    # one engine instance; opening them from independent processes is unsafe.
    class DatabaseLock
      @registry_lock = Monitor.new
      @open_paths = {}

      class << self
        attr_reader :registry_lock, :open_paths
      end

      attr_reader :path

      def initialize(database_path)
        expanded = File.expand_path(database_path)
        FileUtils.mkdir_p(File.dirname(expanded))
        @database_path = if File.exist?(expanded)
          File.realpath(expanded)
        else
          File.join(File.realpath(File.dirname(expanded)), File.basename(expanded))
        end
        @path = "#{@database_path}.lock"
        @file = nil
      end

      def acquire!
        self.class.registry_lock.synchronize do
          raise DatabaseError, "Database '#{@database_path}' is already open in this process" if self.class.open_paths.key?(@database_path)

          FileUtils.mkdir_p(File.dirname(@path))
          @file = File.open(@path, File::RDWR | File::CREAT, 0o600)
          unless @file.flock(File::LOCK_EX | File::LOCK_NB)
            close_file
            raise DatabaseError, "Database '#{@database_path}' is already open by another process"
          end

          self.class.open_paths[@database_path] = self
          true
        end
      rescue Errno::EACCES, Errno::EAGAIN
        close_file
        raise DatabaseError, "Database '#{@database_path}' is already open by another process"
      rescue SystemCallError => error
        close_file
        raise DatabaseError, "Unable to lock database '#{@database_path}': #{error.message}"
      end

      def release
        self.class.registry_lock.synchronize do
          return false unless self.class.open_paths[@database_path].equal?(self)

          self.class.open_paths.delete(@database_path)
          @file&.flock(File::LOCK_UN)
          close_file
          true
        end
      end

      private

      def close_file
        @file&.close unless @file&.closed?
        @file = nil
      end
    end
  end
end
