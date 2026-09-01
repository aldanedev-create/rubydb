# frozen_string_literal: true

require "optparse"

module RubyDB
  module CLI
    # Application - Main CLI application
    class Application
      def initialize
        @output = Output.new
        @formatter = Formatter.new(@output)
        @commands = {}
        @global_options = {
          config: nil,
          env: "development",
          verbose: false,
          quiet: false,
          no_color: false
        }

        register_commands
      end

      def run(argv = ARGV)
        parse_global_options(argv)

        command_name = argv.shift

        if command_name.nil? || command_name == "help"
          print_help
          return 0
        end

        command = @commands[command_name.to_sym]
        if command.nil?
          @output.error("Unknown command: #{command_name}")
          print_help
          return 1
        end

        begin
          command.call(argv, @global_options)
          0
        rescue => e
          @output.error(e.message)
          @output.debug(e.backtrace.join("\n"))
          1
        end
      end

      private

      def register_commands
        @commands[:init] = Commands::Init.new(@output, @formatter).method(:execute)
        @commands[:create] = Commands::Create.new(@output, @formatter).method(:execute)
        @commands[:drop] = Commands::Drop.new(@output, @formatter).method(:execute)
        @commands[:start] = Commands::Start.new(@output, @formatter).method(:execute)
        @commands[:stop] = Commands::Stop.new(@output, @formatter).method(:execute)
        @commands[:restart] = Commands::Restart.new(@output, @formatter).method(:execute)
        @commands[:status] = Commands::Status.new(@output, @formatter).method(:execute)
        @commands[:shell] = Commands::Shell.new(@output, @formatter).method(:execute)
        @commands[:migrate] = Commands::Migrate.new(@output, @formatter).method(:execute)
        @commands[:backup] = Commands::Backup.new(@output, @formatter).method(:execute)
        @commands[:restore] = Commands::Restore.new(@output, @formatter).method(:execute)
        @commands[:snapshot] = Commands::Snapshot.new(@output, @formatter).method(:execute)
        @commands[:branch] = Commands::Branch.new(@output, @formatter).method(:execute)
        @commands[:checkout] = Commands::Checkout.new(@output, @formatter).method(:execute)
        @commands[:merge] = Commands::Merge.new(@output, @formatter).method(:execute)
        @commands[:diff] = Commands::Diff.new(@output, @formatter).method(:execute)
        @commands[:inspect] = Commands::Inspect.new(@output, @formatter).method(:execute)
        @commands[:vacuum] = Commands::Vacuum.new(@output, @formatter).method(:execute)
        @commands[:doctor] = Commands::Doctor.new(@output, @formatter).method(:execute)
      end

      def parse_global_options(argv)
        parser = OptionParser.new do |opts|
          opts.banner = "Usage: rubydb [global_options] command [args]"

          opts.on("-c", "--config FILE", "Configuration file") do |file|
            @global_options[:config] = file
          end

          opts.on("-e", "--env ENV", "Environment (development, test, production)") do |env|
            @global_options[:env] = env
          end

          opts.on("-v", "--verbose", "Verbose output") do
            @global_options[:verbose] = true
          end

          opts.on("-q", "--quiet", "Quiet output") do
            @global_options[:quiet] = true
          end

          opts.on("--no-color", "Disable colored output") do
            @global_options[:no_color] = true
          end

          opts.on("-h", "--help", "Show help") do
            print_help
            exit(0)
          end

          opts.on("--version", "Show version") do
            puts "RubyDB v#{RubyDB::VERSION}"
            exit(0)
          end
        end

        begin
          parser.parse!(argv)
        rescue OptionParser::ParseError => e
          @output.error(e.message)
          print_help
          exit(1)
        end
      end

      def print_help
        @output.puts "RubyDB - Developer-first relational database", :bold
        @output.puts "Version: #{RubyDB::VERSION}"
        @output.puts
        @output.puts "Usage: rubydb [global_options] <command> [args]"
        @output.puts
        @output.puts "Global Options:"
        @output.puts "  -c, --config FILE        Configuration file"
        @output.puts "  -e, --env ENV            Environment (development, test, production)"
        @output.puts "  -v, --verbose            Verbose output"
        @output.puts "  -q, --quiet              Quiet output"
        @output.puts "  --no-color               Disable colored output"
        @output.puts "  -h, --help               Show this help"
        @output.puts "  --version                Show version"
        @output.puts
        @output.puts "Commands:"
        @output.puts "  init                     Initialize a new database"
        @output.puts "  create                   Create a database"
        @output.puts "  drop                     Drop a database"
        @output.puts "  start                    Start the database server"
        @output.puts "  stop                     Stop the database server"
        @output.puts "  restart                  Restart the database server"
        @output.puts "  status                   Show database status"
        @output.puts "  shell                    Open an interactive SQL shell"
        @output.puts "  migrate                  Run database migrations"
        @output.puts "  backup                   Create a database backup"
        @output.puts "  restore                  Restore a database backup"
        @output.puts "  snapshot                 Create a database snapshot"
        @output.puts "  branch                   Manage database branches"
        @output.puts "  checkout                 Switch to a branch"
        @output.puts "  merge                    Merge a branch"
        @output.puts "  diff                     Show differences between branches"
        @output.puts "  inspect                  Inspect database internals"
        @output.puts "  vacuum                   Vacuum the database"
        @output.puts "  doctor                   Run health checks"
        @output.puts
        @output.puts "Run 'rubydb <command> --help' for more information on a command."
      end
    end
  end
end