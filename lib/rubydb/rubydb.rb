# frozen_string_literal: true

# RubyDB - A developer-first relational database for Ruby and Rails
#
# This is the main entry point for the RubyDB library.
# It provides the core database functionality and loads all required components.

require_relative "version"
require_relative "constants"
require_relative "build_info"

require_relative "errors/error"
require_relative "errors/connection_error"
require_relative "errors/database_error"
require_relative "errors/storage_error"
require_relative "errors/execution_error"
require_relative "errors/parser_error"
require_relative "errors/transaction_error"
require_relative "errors/client_error"
require_relative "errors/server_error"

require_relative "storage/engine"
require_relative "storage/storage_manager"
require_relative "storage/file_manager"
require_relative "storage/page"
require_relative "storage/page_header"
require_relative "storage/page_manager"
require_relative "storage/page_allocator"
require_relative "storage/buffer_pool"
require_relative "storage/buffer_frame"
require_relative "storage/record"
require_relative "storage/row"
require_relative "storage/tuple"
require_relative "storage/serializer"
require_relative "storage/deserializer"
require_relative "storage/free_space_map"
require_relative "storage/visibility_map"
require_relative "storage/storage_layout"

require_relative "sql/lexer"
require_relative "sql/token"
require_relative "sql/parser"
require_relative "sql/keywords"
require_relative "sql/operators"
require_relative "sql/ast/node"
require_relative "sql/ast/expression"
require_relative "sql/ast/select"
require_relative "sql/ast/insert"
require_relative "sql/ast/update"
require_relative "sql/ast/delete"
require_relative "sql/ast/create_table"
require_relative "sql/ast/constraint"
require_relative "sql/ast/drop_table"
require_relative "sql/ast/create_index"
require_relative "sql/ast/drop_index"
require_relative "sql/ast/alter_table"
require_relative "sql/ast/create_database"
require_relative "sql/ast/drop_database"
require_relative "sql/ast/create_schema"
require_relative "sql/ast/drop_schema"
require_relative "sql/ast/view"
require_relative "sql/ast/trigger"
require_relative "sql/ast/vacuum"
require_relative "sql/ast/begin_transaction"
require_relative "sql/ast/commit"
require_relative "sql/ast/rollback"
require_relative "sql/ast/savepoint"
require_relative "sql/ast/explain"
require_relative "sql/planner/binder"
require_relative "sql/planner/analyzer"
require_relative "sql/planner/type_checker"

require_relative "execution/executor"
require_relative "execution/plan"
require_relative "execution/planner"
require_relative "execution/optimizer"
require_relative "execution/expression"
require_relative "execution/predicate"
require_relative "execution/scan"
require_relative "execution/sequential_scan"
require_relative "execution/index_scan"
require_relative "execution/insert_executor"
require_relative "execution/update_executor"
require_relative "execution/delete_executor"
require_relative "execution/join_executor"
require_relative "execution/aggregate_executor"
require_relative "execution/sort_executor"
require_relative "execution/limit_executor"
require_relative "execution/distinct_executor"

require_relative "catalog/catalog"
require_relative "catalog/database"
require_relative "catalog/schema"
require_relative "catalog/table"
require_relative "catalog/column"
require_relative "catalog/index"
require_relative "catalog/constraint"
require_relative "catalog/sequence"
require_relative "catalog/view"
require_relative "catalog/trigger"
require_relative "catalog/system_catalog"

require_relative "transactions/transaction"
require_relative "transactions/transaction_manager"
require_relative "transactions/transaction_id"
require_relative "transactions/lock_manager"
require_relative "transactions/lock"
require_relative "transactions/isolation"
require_relative "transactions/savepoint"
require_relative "errors/replication_error"
require_relative "transactions/commit_manager"
require_relative "transactions/transaction_log"

require_relative "indexes/index"
require_relative "indexes/btree"
require_relative "indexes/btree_node"
require_relative "indexes/btree_cursor"
require_relative "indexes/hash_index"
require_relative "indexes/index_scan"
require_relative "indexes/index_manager"

require_relative "wal/wal"
require_relative "wal/record"
require_relative "wal/writer"
require_relative "wal/reader"
require_relative "wal/segment"
require_relative "wal/checkpoint"
require_relative "wal/lsn"
require_relative "wal/archive"

require_relative "recovery/crash_recovery"
require_relative "recovery/checkpoint"
require_relative "recovery/redo"
require_relative "recovery/undo"
require_relative "recovery/consistency"
require_relative "recovery/corruption_detector"
require_relative "recovery/recovery_manager"

require_relative "mvcc/version"
require_relative "mvcc/visibility"
require_relative "mvcc/snapshot"
require_relative "mvcc/version_store"
require_relative "mvcc/vacuum"
require_relative "mvcc/garbage_collector"

require_relative "concurrency/scheduler"
require_relative "concurrency/latch"
require_relative "concurrency/mutex"
require_relative "concurrency/rw_lock"
require_relative "concurrency/deadlock_detector"
require_relative "concurrency/lock_graph"
require_relative "concurrency/worker_pool"

require_relative "constraints/constraint"
require_relative "constraints/primary_key"
require_relative "constraints/foreign_key"
require_relative "constraints/unique"
require_relative "constraints/not_null"
require_relative "constraints/check"
require_relative "constraints/validator"

require_relative "functions/function"
require_relative "functions/scalar"
require_relative "functions/aggregate"
require_relative "functions/string_functions"
require_relative "functions/numeric_functions"
require_relative "functions/date_functions"
require_relative "functions/json_functions"
require_relative "functions/system_functions"

require_relative "types/type"
require_relative "types/integer"
require_relative "types/bigint"
require_relative "types/smallint"
require_relative "types/float"
require_relative "types/decimal"
require_relative "types/boolean"
require_relative "types/text"
require_relative "types/varchar"
require_relative "types/blob"
require_relative "types/date"
require_relative "types/time"
require_relative "types/timestamp"
require_relative "types/json"
require_relative "types/uuid"
require_relative "types/null"

require_relative "security/authentication"
require_relative "security/authorization"
require_relative "security/password"
require_relative "security/credentials"
require_relative "security/user"
require_relative "security/role"
require_relative "security/permissions"
require_relative "security/access_control"
require_relative "security/audit_log"

require_relative "server/server"
require_relative "server/listener"
require_relative "server/connection"
require_relative "server/session"
require_relative "server/connection_pool"
require_relative "server/worker"
require_relative "server/request_handler"
require_relative "server/lifecycle"

require_relative "client/client"
require_relative "client/connection"
require_relative "client/result"
require_relative "client/statement"
require_relative "client/prepared_statement"
require_relative "client/transaction"
require_relative "client/connection_pool"

require_relative "replication/primary"
require_relative "replication/replica"
require_relative "replication/replication_log"
require_relative "replication/replication_stream"
require_relative "replication/replication_manager"
require_relative "replication/replication_slot"
require_relative "replication/failover"

require_relative "backup/backup"
require_relative "backup/restore"
require_relative "backup/snapshot"
require_relative "backup/archive"
require_relative "backup/incremental"
require_relative "backup/verification"

require_relative "branching/branch"
require_relative "branching/branch_manager"
require_relative "branching/copy_on_write"
require_relative "branching/checkout"
require_relative "branching/merge"
require_relative "branching/diff"
require_relative "branching/branch_metadata"

require_relative "history/history"
require_relative "history/change"
require_relative "history/timeline"
require_relative "history/temporal_query"
require_relative "history/as_of"
require_relative "history/history_manager"

require_relative "migrations/migration"
require_relative "migrations/migration_manager"
require_relative "migrations/migration_version"
require_relative "migrations/schema_diff"
require_relative "migrations/schema_version"
require_relative "migrations/migration_lock"

require_relative "rails/adapter"
require_relative "rails/connection"
require_relative "rails/database_statements"
require_relative "rails/schema_statements"
require_relative "rails/quoting"
require_relative "rails/type"
require_relative "rails/migration"
require_relative "rails/transaction"
require_relative "rails/result"

require_relative "configuration/config"
require_relative "configuration/environment"
require_relative "configuration/defaults"
require_relative "configuration/parser"
require_relative "configuration/validation"

require_relative "monitoring/metrics"
require_relative "monitoring/statistics"
require_relative "monitoring/logger"
require_relative "monitoring/health"
require_relative "monitoring/performance"
require_relative "monitoring/events"

require_relative "cli/application"
require_relative "cli/formatter"
require_relative "cli/output"
require_relative "cli/commands/init"
require_relative "cli/commands/create"
require_relative "cli/commands/drop"
require_relative "cli/commands/start"
require_relative "cli/commands/stop"
require_relative "cli/commands/restart"
require_relative "cli/commands/status"
require_relative "cli/commands/shell"
require_relative "cli/commands/migrate"
require_relative "cli/commands/backup"
require_relative "cli/commands/restore"
require_relative "cli/commands/snapshot"
require_relative "cli/commands/branch"
require_relative "cli/commands/checkout"
require_relative "cli/commands/merge"
require_relative "cli/commands/diff"
require_relative "cli/commands/inspect"
require_relative "cli/commands/vacuum"
require_relative "cli/commands/doctor"

module RubyDB
  # Main database class
  class Database
    attr_reader :path, :config, :engine, :connection

    def initialize(path, config = {})
      @path = path
      @config = config
      @engine = nil
      @connection = nil
      @is_open = false
      @lock = Mutex.new
    end

    def connect
      @lock.synchronize do
        return self if @is_open

        # Initialize storage engine
        @engine = Storage::Engine.new(@path, @config)

        # Initialize client connection
        @connection = Client::Client.new(
          database: @path,
          host: @config[:host] || "localhost",
          port: @config[:port] || 7432,
          username: @config[:username] || "rubydb",
          password: @config[:password] || "",
          timeout: @config[:timeout] || 30,
          pool_size: @config[:pool_size] || 1,
          auto_connect: @config.fetch(:auto_connect, true)
        )
        @connection.connect if @config[:auto_connect] != false

        @is_open = true
        self
      end
    rescue => e
      raise ConnectionError, "Failed to connect to database: #{e.message}"
    end

    def execute(sql)
      ensure_connected

      # Parse SQL
      lexer = SQL::Lexer.new(sql)
      tokens = lexer.tokenize
      parser = SQL::Parser.new(tokens)
      statements = parser.parse

      results = []
      statements.each do |stmt|
        # Plan and execute
        planner = Execution::Planner.new(@engine)
        plan = planner.plan(stmt)
        executor = Execution::Executor.new(@engine)
        result = executor.execute(plan)
        results << result
      end

      results.size == 1 ? results.first : results
    rescue => e
      raise ExecutionError, "Failed to execute SQL: #{e.message}"
    end

    def query(sql)
      result = execute(sql)
      if result.is_a?(Hash) && result[:rows]
        result[:rows]
      elsif result.is_a?(Array)
        result.map { |r| r.is_a?(Hash) && r[:rows] ? r[:rows] : r }.flatten
      else
        []
      end
    end

    def close
      @lock.synchronize do
        return true unless @is_open

        @connection&.disconnect if @connection
        @engine&.close if @engine

        @is_open = false
        @engine = nil
        @connection = nil
        true
      end
    end

    def transaction(&block)
      ensure_connected

      begin
        # Begin transaction
        tx_id = @engine.begin_transaction

        # Execute block
        result = block.call if block_given?

        # Commit transaction
        @engine.commit_transaction(tx_id)

        result
      rescue => e
        # Rollback on error
        @engine.rollback_transaction(tx_id) if tx_id
        raise TransactionError, "Transaction failed: #{e.message}"
      end
    end

    def open?
      @is_open
    end

    def stats
      ensure_connected
      @engine.stats
    end

    def tables
      ensure_connected
      @engine.list_tables
    end

    def create_table(name, &block)
      ensure_connected
      @engine.create_table(name, &block)
    end

    def drop_table(name)
      ensure_connected
      @engine.drop_table(name)
    end

    def insert(table, data)
      ensure_connected
      columns = data.keys
      values = data.values
      @engine.insert_row(table, columns, values)
    end

    def select(table, conditions = {})
      ensure_connected
      columns = @engine.table_columns(table)
      @engine.select_rows(table, columns, conditions)
    end

    def update(table, id, data)
      ensure_connected
      @engine.update_row(table, id, data)
    end

    def delete(table, id)
      ensure_connected
      @engine.delete_row(table, id)
    end

    private

    def ensure_connected
      connect unless @is_open
      raise DatabaseError, "Database is not open" unless @is_open
    end
  end

  # Connect to a database
  def self.connect(url)
    # Parse URL: rubydb://local/./path/to/database.rdb
    #         rubydb://user:pass@host:7432/database
    if url.start_with?("rubydb://local/")
      path = url.sub("rubydb://local/", "")
      Database.new(path).connect
    elsif url.start_with?("rubydb://")
      # Server mode
      uri = URI.parse(url)
      config = {
        host: uri.host,
        port: uri.port || 7432,
        username: uri.user,
        password: uri.password,
        database: uri.path.sub("/", "")
      }
      db = Database.new(config[:database], config)
      db.connect
      db
    else
      # Treat as local path
      Database.new(url).connect
    end
  rescue => e
    raise ConnectionError, "Failed to connect: #{e.message}"
  end

  # Open a database file
  def self.open(path, config = {})
    db = Database.new(path, config)
    db.connect
    db
  end

  # Create a new database
  def self.create(path, config = {})
    # Ensure directory exists
    dir = File.dirname(path)
    FileUtils.mkdir_p(dir) unless Dir.exist?(dir)

    # Create and initialize database
    db = Database.new(path, config)
    db.connect

    # Create default schema
    db.execute("CREATE TABLE IF NOT EXISTS schema_migrations (version TEXT PRIMARY KEY, applied_at TIMESTAMP)")
    db.execute("CREATE TABLE IF NOT EXISTS users (id INTEGER PRIMARY KEY AUTOINCREMENT, username TEXT UNIQUE, email TEXT UNIQUE, created_at TIMESTAMP, updated_at TIMESTAMP)")

    db
  rescue => e
    raise DatabaseError, "Failed to create database: #{e.message}"
  end

  # Version information
  def self.version
    VERSION
  end

  # Database information
  def self.info
    {
      name: "RubyDB",
      version: VERSION,
      description: "A developer-first relational database for Ruby and Rails",
      homepage: "https://github.com/rubydb/rubydb",
      license: "MIT"
    }
  end

  # Load a configuration file
  def self.load_config(path)
    Configuration::Config.load(path)
  end

  # Run migrations
  def self.migrate(database, options = {})
    manager = Migrations::MigrationManager.new(database, options)
    manager.migrate
  end

  # Create a backup
  def self.backup(database, options = {})
    backup = Backup::Backup.new(database, options)
    backup.create_backup
  end

  # Restore from backup
  def self.restore(backup_path, options = {})
    restore = Backup::Restore.new(nil, options)
    restore.restore(backup_path)
  end
end
