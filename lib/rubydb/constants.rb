# frozen_string_literal: true

# RubyDB constants and configuration

module RubyDB
  # Database constants
  module Constants
    # Page size in bytes - 8KB default (same as PostgreSQL)
    # This is a good balance between performance and storage efficiency
    DEFAULT_PAGE_SIZE = 8192

    # Page size options
    PAGE_SIZES = [4096, 8192, 16384, 32768].freeze

    # Database file extension
    FILE_EXTENSION = ".rdb"

    # WAL file extension
    WAL_EXTENSION = ".rdb-wal"

    # Shared memory file extension (for WAL)
    SHM_EXTENSION = ".rdb-shm"

    # Default port for RubyDB server
    DEFAULT_PORT = 7432

    # Maximum connections (server mode)
    DEFAULT_MAX_CONNECTIONS = 100

    # Buffer pool size (number of pages cached in memory)
    DEFAULT_BUFFER_POOL_SIZE = 1000

    # WAL segment size (16MB default)
    DEFAULT_WAL_SEGMENT_SIZE = 16 * 1024 * 1024

    # Maximum SQL statement length
    MAX_SQL_LENGTH = 1_000_000

    # Maximum identifier length
    MAX_IDENTIFIER_LENGTH = 63

    # Transaction isolation levels
    module IsolationLevel
      READ_UNCOMMITTED = 0
      READ_COMMITTED = 1
      REPEATABLE_READ = 2
      SERIALIZABLE = 3
    end

    # Log levels
    module LogLevel
      DEBUG = 0
      INFO = 1
      WARN = 2
      ERROR = 3
      FATAL = 4
    end
  end

  # Error codes
  module ErrorCodes
    OK = 0
    ERROR = 1
    IO_ERROR = 2
    CORRUPTION = 3
    CONSTRAINT_VIOLATION = 4
    TRANSACTION_ABORTED = 5
    LOCK_TIMEOUT = 6
    DEADLOCK_DETECTED = 7
    PERMISSION_DENIED = 8
    NOT_FOUND = 9
    ALREADY_EXISTS = 10
  end
end