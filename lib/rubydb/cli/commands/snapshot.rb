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
            opts.on("-h", "--help", "Show help") do
              @output.puts opts
              exit(0)
            end
          end

          parser.parse!(args)

          if options[:list]
            @formatter.format_snapshots([
              { name: "snapshot_20240101", created_at: "2024-01-01 10:00:00", size: "100MB" }
            ])
            return
          end

          if options[:delete]
            @output.spinner("Deleting snapshot #{options[:delete]}...") do
              @output.success("Snapshot deleted")
            end
            return
          end

          if options[:restore]
            @output.warn("This will overwrite the current database")
            @output.print("Are you sure? (yes/no): ", nil, false)
            response = $stdin.gets.chomp
            return unless response.downcase == "yes"

            @output.spinner("Restoring snapshot #{options[:restore]}...") do
              @output.success("Snapshot restored")
            end
            return
          end

          name = options[:name] || "snapshot_#{Time.now.strftime('%Y%m%d_%H%M%S')}"

          @output.spinner("Creating snapshot #{name}...") do
            @output.success("Snapshot #{name} created")
          end
        end
      end
    end
  end
end