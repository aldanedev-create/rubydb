# frozen_string_literal: true

module RubyDB
  module CLI
    # Output - Handles CLI output formatting
    class Output
      COLORS = {
        reset: "\e[0m",
        bold: "\e[1m",
        red: "\e[31m",
        green: "\e[32m",
        yellow: "\e[33m",
        blue: "\e[34m",
        magenta: "\e[35m",
        cyan: "\e[36m",
        white: "\e[37m",
        gray: "\e[90m",
        bright_red: "\e[91m",
        bright_green: "\e[92m",
        bright_yellow: "\e[93m",
        bright_blue: "\e[94m"
      }

      def initialize(no_color: false, quiet: false, format: :text)
        @no_color = no_color
        @quiet = quiet
        @format = format
        @buffer = []
      end

      def print(message, color = nil, newline = true)
        return if @quiet

        if color && !@no_color
          message = "#{COLORS[color]}#{message}#{COLORS[:reset]}"
        end

        $stdout.print(message)
        $stdout.print("\n") if newline
      end

      def puts(message = "", color = nil)
        print(message, color, true)
      end

      def error(message)
        print("Error: #{message}", :bright_red)
      end

      def warn(message)
        print("Warning: #{message}", :yellow)
      end

      def success(message)
        print("✓ #{message}", :green)
      end

      def info(message)
        print("ℹ #{message}", :blue)
      end

      def debug(message)
        print("DEBUG: #{message}", :gray) if ENV["RUBYDB_DEBUG"]
      end

      def table(headers, rows, options = {})
        return if rows.empty? && !options[:show_empty]

        # Calculate column widths
        widths = headers.map.with_index do |h, i|
          max = h.to_s.length
          rows.each do |row|
            val = row[i].to_s
            max = val.length if val.length > max
          end
          max
        end

        # Print headers
        header_line = headers.each_with_index.map { |h, i| h.to_s.ljust(widths[i]) }.join("  ")
        puts header_line, :bold
        puts "-" * header_line.length, :gray

        # Print rows
        rows.each do |row|
          line = row.each_with_index.map { |val, i| val.to_s.ljust(widths[i]) }.join("  ")
          puts line
        end

        puts "\nTotal: #{rows.size}" if options[:show_count]
      end

      def json(data)
        require "json"
        puts JSON.pretty_generate(data)
      end

      def yaml(data)
        require "yaml"
        puts data.to_yaml
      end

      def progress(current, total, message = nil)
        percent = (current.to_f / total * 100).round(1)
        bar_length = 40
        filled = (percent / 100 * bar_length).round
        bar = "[" + "=" * filled + " " * (bar_length - filled) + "]"

        if message
          print("\r#{message} #{bar} #{percent}%", nil, false)
        else
          print("\r#{bar} #{percent}%", nil, false)
        end

        print("\n") if current == total
      end

      def spinner(message = nil)
        return unless block_given?

        chars = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
        index = 0
        thread = Thread.new do
          while true
            print("\r#{chars[index % chars.length]} #{message}", nil, false)
            index += 1
            sleep(0.1)
          end
        end

        result = yield
        thread.kill
        print("\r✓ #{message}", :green)
        puts
        result
      end

      def heading(text, level = 1)
        case level
        when 1
          puts "#{'=' * text.length}", :bold
          puts text, :bold
          puts "#{'=' * text.length}", :bold
        when 2
          puts text, :bold
          puts "-" * text.length, :gray
        else
          puts text, :bold
        end
        puts
      end

      def write(data)
        @buffer << data
      end

      def flush
        result = @buffer.join("\n")
        @buffer.clear
        result
      end

      def quiet?
        @quiet
      end
    end
  end
end
