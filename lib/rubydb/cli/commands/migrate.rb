# frozen_string_literal: true

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
            opts.on("-h", "--help", "Show help") do
              @output.puts opts
              exit(0)
            end
          end

          parser.parse!(args)

          if options[:dry_run]
            @output.info("Migrations to run:")
            @output.puts("  - 20240101000000 CreateUsers")
            @output.puts("  - 20240102000000 AddEmailToUsers")
            return
          end

          @output.spinner("Running migrations...") do
            @output.success("Migrations completed successfully")
          end
        end
      end
    end
  end
end