# frozen_string_literal: true

module RubyDB
  module CLI
    module Commands
      # Drop - Drop a database
      class Drop
        def initialize(output, formatter)
          @output = output
          @formatter = formatter
        end

        def execute(args, options)
          parser = OptionParser.new do |opts|
            opts.banner = "Usage: rubydb drop [options]"
            opts.on("-n", "--name NAME", "Database name") do |name|
              options[:name] = name
            end
            opts.on("-f", "--force", "Force drop") do
              options[:force] = true
            end
            opts.on("--database PATH", "Database path") { |path| options[:database] = path }
            opts.on("--dir DIR", "Database data directory") { |dir| options[:dir] = dir }
            opts.on("-h", "--help", "Show help") do
              @output.puts opts
              exit(0)
            end
          end

          parser.parse!(args)

          name = options[:name] || "rubydb"
          db_path = options[:database] || File.join(options[:dir] || "data", "#{name}.rdb")
          unless File.file?(db_path)
            @output.error("Database not found at #{db_path}")
            return 1
          end

          unless options[:force]
            @output.warn("This will permanently delete database '#{name}'")
            @output.print("Are you sure? (yes/no): ", nil, false)
            response = $stdin.gets.chomp
            return unless response.downcase == "yes"
          end

          @output.spinner("Dropping database #{name}...") do
            [db_path, "#{db_path}.metadata", "#{db_path}.visibility", "#{db_path}.mvcc", "#{db_path}.wal"].each do |path|
              FileUtils.rm_rf(path) if File.exist?(path)
            end
            @output.success("Database #{name} dropped")
          end
          0
        end
      end
    end
  end
end
