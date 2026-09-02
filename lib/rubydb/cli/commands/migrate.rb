# frozen_string_literal: true

require "optparse"

module RubyDB
  module CLI
    module Commands
      # Migrate - Run database migrations
      class Migrate
        def initialize(output, formatter)
          @output = output
          @formatter = formatter
        end

        def execute(args, options)
          parser = OptionParser.new do |opts|
            opts.banner = "Usage: rubydb migrate [options]"
            opts.on("-v", "--version VERSION", "Migrate to version") do |version|
              options[:version] = version
            end
            opts.on("-s", "--steps N", Integer, "Rollback N steps") do |steps|
              options[:steps] = steps
            end
            opts.on("--down", "Migrate down") do
              options[:down] = true
            end
            opts.on("--dry-run", "Show what would be run") do
              options[:dry_run] = true
            end
            opts.on("--database PATH", "Database path") { |path| options[:database] = path }
            opts.on("--path DIR", "Migration directory") { |path| options[:migrations_path] = path }
            opts.on("-h", "--help", "Show help") do
              @output.puts opts
              exit(0)
            end
          end

          parser.parse!(args)

          database = RubyDB::Database.new(options[:database] || "data/rubydb.rdb", auto_connect: false).connect
          manager = RubyDB::Migrations::MigrationManager.new(
            database,
            path: options[:migrations_path] || "db/migrate",
            version: options[:version]
          )
          if options[:dry_run]
            @formatter.format_migrations(manager.status)
          elsif options[:down]
            manager.rollback(options[:steps] || 1)
            @output.success("Migration rollback completed")
          else
            manager.migrate
            @output.success("Migrations completed successfully")
          end
          0
        ensure
          database&.close
        end
      end
    end
  end
end
