# frozen_string_literal: true

module RubyDB
  module CLI
    module Commands
      # Create - Create a database
      class Create
        def initialize(output, formatter)
          @output = output
          @formatter = formatter
        end

        def execute(args, options)
          parser = OptionParser.new do |opts|
            opts.banner = "Usage: rubydb create [options]"
            opts.on("-n", "--name NAME", "Database name") do |name|
              options[:name] = name
            end
            opts.on("-d", "--dir DIR", "Data directory") do |dir|
              options[:dir] = dir
            end
            opts.on("-f", "--force", "Force create") do
              options[:force] = true
            end
            opts.on("--database PATH", "Database path") { |path| options[:database] = path }
            opts.on("-h", "--help", "Show help") do
              @output.puts opts
              exit(0)
            end
          end

          parser.parse!(args)

          name = options[:name] || "rubydb"
          dir = options[:dir] || "data"
          db_path = options[:database] || File.join(dir, "#{name}.rdb")
          if File.exist?(db_path) && !options[:force]
            @output.error("Database already exists at #{db_path}. Use --force to recreate it.")
            return 1
          end

          @output.spinner("Creating database #{name}...") do
            FileUtils.mkdir_p(File.dirname(db_path))
            if options[:force]
              [db_path, "#{db_path}.metadata", "#{db_path}.visibility", "#{db_path}.mvcc", "#{db_path}.wal"].each do |path|
                FileUtils.rm_rf(path) if File.exist?(path)
              end
            end
            engine = RubyDB::Storage::Engine.new(db_path, auto_vacuum: false)
            engine.close
            @output.success("Database #{name} created at #{db_path}")
          end
          0
        end
      end
    end
  end
end
