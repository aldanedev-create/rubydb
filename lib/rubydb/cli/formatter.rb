# frozen_string_literal: true

require "time"

module RubyDB
  module CLI
    # Formatter - Formats CLI output
    class Formatter
      def initialize(output)
        @output = output
      end

      def format_status(status_data)
        @output.heading("RubyDB Status", 1)

        @output.puts "Database: #{status_data[:database] || 'N/A'}"
        @output.puts "Mode: #{status_data[:mode] || 'N/A'}"
        @output.puts "Status: #{status_data[:status] || 'N/A'}"
        @output.puts "Version: #{status_data[:version] || RubyDB::VERSION}"
        @output.puts "PID: #{status_data[:pid] || 'N/A'}"
        @output.puts "Uptime: #{format_uptime(status_data[:uptime])}"
        @output.puts "Connections: #{status_data[:connections] || 0}"
        @output.puts "Tables: #{status_data[:tables] || 0}"
        @output.puts "Storage: #{format_size(status_data[:storage_size])}"
        @output.puts "Memory: #{format_size(status_data[:memory_usage])}"
        @output.puts "WAL: #{status_data[:wal_enabled] ? 'Enabled' : 'Disabled'}"

        if status_data[:replication]
          @output.puts "\nReplication:"
          @output.puts "  Role: #{status_data[:replication][:role]}"
          @output.puts "  Status: #{status_data[:replication][:status]}"
          @output.puts "  Lag: #{status_data[:replication][:lag_ms]}ms"
        end

        if status_data[:branch]
          @output.puts "\nBranch:"
          @output.puts "  Current: #{status_data[:branch][:current]}"
          @output.puts "  Total: #{status_data[:branch][:total]}"
        end
      end

      def format_backups(backups)
        return @output.puts("No backups found", :yellow) if backups.empty?

        headers = ["Name", "Type", "Size", "Created At", "Age"]
        rows = backups.map do |b|
          [
            b[:name],
            b[:type],
            format_size(b[:size]),
            b[:created_at],
            format_age(b[:age])
          ]
        end

        @output.table(headers, rows, show_count: true)
      end

      def format_branches(branches)
        return @output.puts("No branches found", :yellow) if branches.empty?

        headers = ["Name", "State", "Commits", "Created At", "Parent"]
        rows = branches.map do |b|
          [
            b[:name],
            b[:state],
            b[:commit_count],
            b[:created_at],
            b[:parent_branch] || "-"
          ]
        end

        @output.table(headers, rows, show_count: true)
      end

      def format_tables(tables)
        return @output.puts("No tables found", :yellow) if tables.empty?

        headers = ["Table", "Rows", "Columns", "Size", "Created At"]
        rows = tables.map do |t|
          [
            t[:name],
            t[:row_count],
            t[:column_count],
            format_size(t[:size]),
            t[:created_at]
          ]
        end

        @output.table(headers, rows, show_count: true)
      end

      def format_migrations(migrations)
        return @output.puts("No migrations found", :yellow) if migrations.empty?

        migrations = migrations.map do |migration|
          migration.merge(applied: migration[:applied] || migration[:state]&.to_sym == :applied)
        end

        headers = ["Version", "Name", "Status", "Applied At"]
        rows = migrations.map do |m|
          [
            m[:version],
            m[:name],
            m[:applied] ? "✓ Applied" : "⏳ Pending",
            m[:applied_at] || "-"
          ]
        end

        @output.table(headers, rows, show_count: true)
      end

      def format_diff(diff_data)
        @output.heading("Database Diff", 2)

        if diff_data[:added_tables].any?
          @output.puts "Added Tables:", :green
          diff_data[:added_tables].each { |t| @output.puts "  + #{t}" }
        end

        if diff_data[:removed_tables].any?
          @output.puts "\nRemoved Tables:", :red
          diff_data[:removed_tables].each { |t| @output.puts "  - #{t}" }
        end

        if diff_data[:changed_tables].any?
          @output.puts "\nChanged Tables:", :yellow
          diff_data[:changed_tables].each do |t|
            @output.puts "  ~ #{t[:name]}"
            t[:changes].each do |change|
              @output.puts "    - #{change}"
            end
          end
        end

        if diff_data[:added_columns].any?
          @output.puts "\nAdded Columns:", :green
          diff_data[:added_columns].each do |c|
            @output.puts "  + #{c[:table]}.#{c[:column]} (#{c[:type]})"
          end
        end

        if diff_data[:removed_columns].any?
          @output.puts "\nRemoved Columns:", :red
          diff_data[:removed_columns].each do |c|
            @output.puts "  - #{c[:table]}.#{c[:column]}"
          end
        end

        if diff_data[:changed_columns].any?
          @output.puts "\nChanged Columns:", :yellow
          diff_data[:changed_columns].each do |c|
            @output.puts "  ~ #{c[:table]}.#{c[:column]} (#{c[:old_type]} → #{c[:new_type]})"
          end
        end

        if diff_data[:added_tables].empty? && diff_data[:removed_tables].empty? &&
           diff_data[:changed_tables].empty? && diff_data[:added_columns].empty? &&
           diff_data[:removed_columns].empty? && diff_data[:changed_columns].empty?
          @output.puts "No differences found", :green
        end
      end

      def format_doctor(results)
        @output.heading("Database Health Check", 1)

        results[:checks].each do |check|
          status = check[:passed] ? "✓" : "✗"
          color = check[:passed] ? :green : :red
          @output.puts "#{status} #{check[:name]}", color

          if check[:details]
            @output.puts "  Details:", :gray
            check[:details].each do |key, value|
              @output.puts "    #{key}: #{value}", :gray
            end
          end

          if check[:errors] && check[:errors].any?
            @output.puts "  Errors:", :red
            check[:errors].each { |e| @output.puts "    - #{e}", :red }
          end
        end

        @output.puts "\nOverall: #{results[:passed] ? 'Healthy' : 'Issues Found'}", results[:passed] ? :green : :red
        @output.puts "Checks Passed: #{results[:passed_count]}/#{results[:total_count]}"
      end

      private

      def format_size(bytes)
        return "0 B" if bytes.to_i == 0
        units = ["B", "KB", "MB", "GB", "TB"]
        exp = (Math.log(bytes) / Math.log(1024)).floor
        size = bytes / (1024.0 ** exp)
        "#{size.round(2)} #{units[exp]}"
      end

      def format_age(seconds)
        return "N/A" unless seconds
        return "#{seconds.round}s" if seconds < 60
        return "#{(seconds / 60).round}m" if seconds < 3600
        return "#{(seconds / 3600).round}h" if seconds < 86400
        "#{(seconds / 86400).round}d"
      end

      def format_uptime(seconds)
        return "N/A" unless seconds
        days = (seconds / 86400).to_i
        hours = ((seconds % 86400) / 3600).to_i
        minutes = ((seconds % 3600) / 60).to_i

        parts = []
        parts << "#{days}d" if days > 0
        parts << "#{hours}h" if hours > 0 || days > 0
        parts << "#{minutes}m"
        parts.join(" ")
      end
    end
  end
end
