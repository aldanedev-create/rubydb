# frozen_string_literal: true

module RubyDB
  module CLI
    module Commands
      class Backup
        def initialize(output, formatter)
          @output = output
          @formatter = formatter
        end

        def execute(args, options)
          parser = OptionParser.new do |opts|
            opts.banner = "Usage: rubydb backup [options]"
            opts.on("-t", "--type TYPE", "Backup type (full, incremental, differential)") do |type|
              options[:type] = type.to_sym
            end
            opts.on("-d", "--dir DIR", "Backup directory") do |dir|
              options[:dir] = dir
            end
            opts.on("--compress", "Compress backup") do
              options[:compress] = true
            end
            opts.on("--no-verify", "Skip verification") do
              options[:no_verify] = true
            end
            opts.on("--database PATH", "Database path") { |path| options[:database] = path }
            opts.on("-h", "--help", "Show help") do
              @output.puts opts
              exit(0)
            end
          end

          parser.parse!(args)

          # Get real config
          config = RubyDB::Configuration::Config.instance
          db_path = options[:database] || config.get("storage.data_dir") || "data/rubydb.rdb"
          backup_dir = options[:dir] || config.get("backup.backup_dir") || "backups"

          # Create backup instance
          engine = RubyDB::Storage::Engine.new(db_path, {})
          backup = RubyDB::Backup::Backup.new(engine,
            backup_dir: backup_dir,
            compress: options[:compress] != false,
            verify_after_backup: !options[:no_verify]
          )

          @output.spinner("Creating #{options[:type] || 'full'} backup...") do
            result = backup.create_backup(type: options[:type] || :full)

            if result[:success]
              @output.success("Backup created successfully")
              @output.puts("  Name: #{result[:backup_name]}")
              @output.puts("  Size: #{format_size(result[:size])}")
              @output.puts("  Path: #{result[:backup_path]}")
              @output.puts("  Time: #{result[:elapsed_ms].round(2)}ms")
            else
              @output.error("Backup failed: #{result[:error]}")
              return 1
            end
          end

          0
        ensure
          engine&.close if engine&.open?
        end

        private

        def format_size(bytes)
          return "0 B" if bytes.to_i == 0
          units = ["B", "KB", "MB", "GB", "TB"]
          exp = (Math.log(bytes) / Math.log(1024)).floor
          size = bytes / (1024.0 ** exp)
          "#{size.round(2)} #{units[exp]}"
        end
      end
    end
  end
end
