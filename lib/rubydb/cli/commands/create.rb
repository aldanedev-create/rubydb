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
            opts.on("-h", "--help", "Show help") do
              @output.puts opts
              exit(0)
            end
          end

          parser.parse!(args)

          name = options[:name] || "rubydb"
          dir = options[:dir] || "data"

          @output.spinner("Creating database #{name}...") do
            FileUtils.mkdir_p(dir) unless Dir.exist?(dir)
            @output.success("Database #{name} created")
          end
        end
      end
    end
  end
end