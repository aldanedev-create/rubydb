# frozen_string_literal: true

require "fileutils"
require "time"

module RubyDB
  module Migrations
    class MigrationError < StandardError; end unless const_defined?(:MigrationError)

    # Loads and applies migrations with durable version tracking and a
    # cross-process lock. Migration files must evaluate to a Migration.
    class MigrationManager
      attr_reader :database, :engine, :migrations, :stats

      def initialize(database, options = {})
        @database = database
        @engine = database.respond_to?(:engine) ? database.engine : database
        @options = options
        @migration_path = options[:path] || options[:migrations_path] || "db/migrate"
        @migrations = options[:migrations] || load_migrations
        @lock = MigrationLock.new(@engine, options)
        @stats = { applied: 0, rolled_back: 0, failed: 0 }
      end

      def migrate
        with_lock do
          ensure_schema
          applied = applied_versions
          target = target_version
          pending = ordered_migrations.reject { |migration| applied.key?(migration.version.to_s) }
          pending = pending.select { |migration| migration_key(migration.version) <= migration_key(target) } if target
          apply_migrations(pending)
        end
      end

      def rollback(steps = 1)
        raise ArgumentError, "steps must be a positive integer" unless steps.is_a?(Integer) && steps.positive?

        with_lock do
          ensure_schema
          applied = applied_versions
          to_rollback = ordered_migrations.select { |m| applied.key?(m.version.to_s) }
                                      .sort_by { |m| migration_key(m.version) }
                                      .reverse
                                      .first(steps)
          to_rollback.each { |migration| rollback_migration(migration) }
          to_rollback
        end
      end

      def status
        ensure_schema
        applied = applied_versions
        ordered_migrations.map do |migration|
          record = applied[migration.version.to_s]
          { version: migration.version.to_s, name: migration.name,
            state: record ? :applied : :pending, checksum: record && record[:checksum] }
        end
      end

      private

      def with_lock
        raise MigrationError, "could not acquire migration lock" unless @lock.acquire_lock
        yield
      ensure
        @lock.release_lock if @lock&.lock_acquired?
      end

      def ensure_schema
        @database.execute("CREATE TABLE IF NOT EXISTS schema_migrations (version TEXT PRIMARY KEY, migration_name TEXT, applied_at TIMESTAMP, checksum TEXT)")
        ensure_column("migration_name", "TEXT")
        ensure_column("checksum", "TEXT")
      end

      def ensure_column(name, type)
        @database.execute("ALTER TABLE schema_migrations ADD COLUMN #{name} #{type}")
      rescue StandardError => error
        raise unless error.message =~ /already exists|duplicate|exists/i
      end

      def applied_versions
        rows = @database.query("SELECT version, migration_name, checksum FROM schema_migrations")
        Array(rows).each_with_object({}) do |row, result|
          version = row[:version] || row["version"]
          result[version.to_s] = { name: row[:migration_name] || row["migration_name"], checksum: row[:checksum] || row["checksum"] }
        end
      end

      def apply_migrations(migrations)
        migrations.each do |migration|
          existing = applied_versions[migration.version.to_s]
          if existing && existing[:checksum] && existing[:checksum] != migration_checksum(migration)
            raise MigrationError, "migration checksum mismatch for #{migration.version}"
          end

          begin
            @database.transaction do
              migration.apply_up(@engine)
              insert_version(migration)
            end
            @stats[:applied] += 1
          rescue StandardError
            migration.mark_failed
            @stats[:failed] += 1
            raise
          end
        end
      end

      def rollback_migration(migration)
        @database.transaction do
          migration.apply_down(@engine)
          @database.execute("DELETE FROM schema_migrations WHERE version = #{quote(migration.version.to_s)}")
        end
        @stats[:rolled_back] += 1
      end

      def insert_version(migration)
        values = [migration.version.to_s, migration.name.to_s, Time.now.iso8601, migration_checksum(migration)].map { |v| quote(v) }
        @database.execute("INSERT INTO schema_migrations (version, migration_name, applied_at, checksum) VALUES (#{values.join(', ')})")
      end

      def quote(value)
        "'#{value.to_s.gsub("'", "''")}'"
      end

      def ordered_migrations
        @migrations.sort_by { |migration| migration_key(migration.version) }
      end

      def migration_key(version)
        version.to_s =~ /\A\d+\z/ ? version.to_i : version.to_s
      end

      def target_version
        @options[:version]
      end

      def migration_checksum(migration)
        migration.instance_variable_get(:@checksum) || Digest::SHA256.hexdigest(migration.to_json)[0...16]
      end

      def load_migrations
        return [] unless Dir.exist?(@migration_path)

        Dir.glob(File.join(@migration_path, "*.rb")).sort.map do |path|
          migration = eval(File.read(path), TOPLEVEL_BINDING, path, 1)
          unless migration.is_a?(Migration)
            raise MigrationError, "#{path} must evaluate to a Migration"
          end
          migration
        end
      end
    end
  end
end
