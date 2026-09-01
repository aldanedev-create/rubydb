# frozen_string_literal: true

require "fileutils"

module RubyDB
  module CLI
    module Commands
      class Init
        def initialize(output, formatter)
          @output = output
          @formatter = formatter
        end

        def execute(args, options)
          parser = OptionParser.new do |opts|
            opts.banner = "Usage: rubydb init [options]"
            opts.on("-n", "--name NAME", "Database name") do |name|
              options[:name] = name
            end
            opts.on("-d", "--dir DIR", "Data directory") do |dir|
              options[:dir] = dir
            end
            opts.on("-f", "--force", "Force overwrite") do
              options[:force] = true
            end
            opts.on("-h", "--help", "Show help") do
              @output.puts opts
              exit(0)
            end
          end

          parser.parse!(args)

          name = options[:name] || "rubydb"
          dir = options[:dir] || "data"
          db_path = File.join(dir, "#{name}.rdb")

          if File.exist?(db_path) && !options[:force]
            @output.error("Database already exists at #{db_path}. Use --force to overwrite.")
            return 1
          end

          @output.spinner("Initializing database #{name}...") do
            # Create directory
            FileUtils.mkdir_p(dir) unless Dir.exist?(dir)

            # Initialize storage engine
            engine = RubyDB::Storage::Engine.new(db_path, {})
            
            # Create default tables
            create_default_tables(engine)
            
            # Create default user if not exists
            create_default_user(engine) if options[:user]

            @output.success("Database #{name} initialized at #{db_path}")
          end

          0
        end

        private

        def create_default_tables(engine)
          # Create schema_migrations table
          engine.create_table("schema_migrations") do |t|
            t.column("version", :text, primary_key: true)
            t.column("applied_at", :timestamp)
          end

          # Create users table
          engine.create_table("users") do |t|
            t.column("id", :integer, primary_key: true, auto_increment: true)
            t.column("username", :text, unique: true, null: false)
            t.column("email", :text, unique: true)
            t.column("password_hash", :text)
            t.column("salt", :text)
            t.column("created_at", :timestamp)
            t.column("updated_at", :timestamp)
          end

          # Create sessions table
          engine.create_table("sessions") do |t|
            t.column("id", :integer, primary_key: true, auto_increment: true)
            t.column("user_id", :integer)
            t.column("token", :text, unique: true)
            t.column("created_at", :timestamp)
            t.column("expires_at", :timestamp)
          end
        end

        def create_default_user(engine)
          # Create admin user
          engine.insert_row("users", 
            ["username", "email", "created_at"], 
            ["admin", "admin@localhost", Time.now]
          )
        end
      end
    end
  end
end