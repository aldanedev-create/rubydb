# frozen_string_literal: true

module RubyDB
  module CLI
    module Commands
      # Snapshot - Create a database snapshot
      class Snapshot
        def initialize(output, formatter)
          @output = output
          @formatter = formatter
        end

        def execute(args, options)
          parser = OptionParser.new do |opts|
            opts.banner = "Usage: rubydb snapshot [options]"
            opts.on("-n", "--name NAME", "Snapshot name") do |name|
              options[:name] = name
            end
            opts.on("-l", "--list", "List snapshots") do
              options[:list] = true
            end
            opts.on("-d", "--delete NAME", "Delete snapshot") do |name|
              options[:delete] = name
            end
            opts.on("-r", "--restore NAME", "Restore snapshot") do |name|
              options[:restore] = name
            end
            opts.on("--database PATH", "Database path") { |path| options[:database] = path }
            opts.on("--dir DIR", "Snapshot directory") { |path| options[:snapshot_dir] = path }
            opts.on("-h", "--help", "Show help") do
              @output.puts opts
              exit(0)
            end
          end

          parser.parse!(args)

          database = RubyDB::Database.new(options[:database] || "data/rubydb.rdb", auto_connect: false).connect
          snapshots = RubyDB::Backup::Snapshot.new(
            database.engine, snapshot_dir: options[:snapshot_dir] || "snapshots"
          )

          if options[:list]
            @formatter.format_snapshots(snapshots.list_snapshots)
            return 0
          end

          if options[:delete]
            result = snapshots.delete_snapshot(options[:delete])
            raise result[:error] unless result[:success]
            @output.success("Snapshot #{options[:delete]} deleted")
            return 0
          end

          if options[:restore]
            @output.warn("This will overwrite the current database")
            @output.print("Are you sure? (yes/no): ", nil, false)
            response = $stdin.gets.chomp
            return unless response.downcase == "yes"

            result = snapshots.restore_snapshot(options[:restore])
            raise result[:error] unless result[:success]
            @output.success("Snapshot #{options[:restore]} restored")
            return 0
          end

          name = options[:name] || "snapshot_#{Time.now.strftime('%Y%m%d_%H%M%S')}"

          result = snapshots.create_snapshot(name)
          raise result[:error] unless result[:success]
          @output.success("Snapshot #{name} created")
          0
        ensure
          database&.close
        end
      end
    end
  end
end
