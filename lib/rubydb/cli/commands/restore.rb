# frozen_string_literal: true

module RubyDB
  module CLI
    module Commands
      class Restore
        def initialize(output, formatter)
          @output = output
          @formatter = formatter
        end

        def execute(args, options)
          parser = OptionParser.new do |opts|
            opts.banner = "Usage: rubydb restore [options]"
            opts.on("-b", "--backup NAME", "Backup name") do |name|
              options[:backup] = name
            end
            opts.on("-l", "--latest", "Restore latest backup") do
              options[:latest] = true
            end
            opts.on("--point-in-time TIME", "Restore to point in time") do |time|
              options[:point_in_time] = time
            end
            opts.on("--dry-run", "Show what would be restored") do
              options[:dry_run] = true
            end
            opts.on("-f", "--force", "Force restore") do
              options[:force] = true
            end
            opts.on("-h", "--help", "Show help") do
              @output.puts opts
              exit(0)
            end
          end

          parser.parse!(args)

          # Get real config
          config = RubyDB::Configuration::Config.instance
          db_path = config.get("storage.data_dir") || "data/rubydb.rdb"
          backup_dir = config.get("backup.backup_dir") || "backups"

          unless options[:force]
            @output.warn("This will overwrite the current database")
            @output.print("Are you sure? (yes/no): ", nil, false)
            response = $stdin.gets.chomp
            return 1 unless response.downcase == "yes"
          end

          # Create restore instance
          engine = RubyDB::Storage::Engine.new(db_path, {})
          restore = RubyDB::Backup::Restore.new(engine, backup_dir: backup_dir)

          if options[:latest]
            @output.spinner("Restoring latest backup...") do
              result = restore.restore_latest

              if result[:success]
                @output.success("Backup restored successfully")
              else
                @output.error("Restore failed: #{result[:error]}")
                return 1
              end
            end
          elsif options[:backup]
            backup_path = File.join(backup_dir, options[:backup])
            @output.spinner("Restoring backup #{options[:backup]}...") do
              result = restore.restore(backup_path)

              if result[:success]
                @output.success("Backup restored successfully")
              else
                @output.error("Restore failed: #{result[:error]}")
                return 1
              end
            end
          elsif options[:point_in_time]
            @output.spinner("Restoring to point in time #{options[:point_in_time]}...") do
              result = restore.restore_point_in_time(options[:point_in_time])

              if result[:success]
                @output.success("Database restored to #{options[:point_in_time]}")
              else
                @output.error("Restore failed: #{result[:error]}")
                return 1
              end
            end
          else
            @output.error("Please specify --backup, --latest, or --point-in-time")
            @output.puts parser
            return 1
          end

          0
        end
      end
    end
  end
end