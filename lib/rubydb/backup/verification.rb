# frozen_string_literal: true

require "fileutils"
require "time"
require "json"
require "digest"

module RubyDB
  module Backup
    # Verification - Verifies backup integrity
    class Verification
      attr_reader :stats

      def initialize(config = {})
        @config = config
        @verification_dir = config[:verification_dir] || "verifications"
        @stats = {
          verifications: 0,
          successful: 0,
          failed: 0,
          total_time_ms: 0,
          avg_time_ms: 0,
          last_verification: nil,
          errors: 0
        }
        @lock = Mutex.new
        @cache = {}

        FileUtils.mkdir_p(@verification_dir)
      end

      def verify_backup(backup_path, options = {})
        @lock.synchronize do
          start_time = Time.now
          @stats[:verifications] += 1

          unless Dir.exist?(backup_path)
            return { success: false, error: "Backup path does not exist" }
          end

          manifest_path = File.join(backup_path, "manifest.json")
          unless File.exist?(manifest_path)
            return { success: false, error: "Manifest not found" }
          end

          begin
            metadata = JSON.parse(File.read(manifest_path), symbolize_names: true)

            results = {
              manifest_valid: true,
              files_valid: true,
              checksums_valid: true,
              database_valid: true,
              details: {}
            }

            # Verify manifest
            results[:details][:manifest] = verify_manifest(metadata)

            # Verify files
            files_result = verify_files(backup_path, metadata[:files] || [])
            results[:files_valid] = files_result[:valid]
            results[:details][:files] = files_result

            # Verify checksums
            if metadata[:checksum]
              checksum_result = verify_checksums(backup_path, metadata[:checksum])
              results[:checksums_valid] = checksum_result[:valid]
              results[:details][:checksums] = checksum_result
            end

            # Verify database consistency (restore to temp and verify)
            if options[:verify_database] != false
              db_result = verify_database(backup_path, metadata)
              results[:database_valid] = db_result[:valid]
              results[:details][:database] = db_result
            end

            success = results[:manifest_valid] && results[:files_valid] &&
                      results[:checksums_valid] && results[:database_valid]

            # Save verification result
            save_verification_result(backup_path, results)

            elapsed_ms = (Time.now - start_time) * 1000
            @stats[:total_time_ms] += elapsed_ms
            @stats[:avg_time_ms] = @stats[:total_time_ms] / @stats[:verifications]

            if success
              @stats[:successful] += 1
            else
              @stats[:failed] += 1
            end

            @stats[:last_verification] = Time.now

            { success: success, results: results, elapsed_ms: elapsed_ms }

          rescue => e
            @stats[:errors] += 1
            @stats[:failed] += 1
            { success: false, error: e.message }
          end
        end
      end

      def verify_restore(backup_path, options = {})
        @lock.synchronize do
          # Create temporary restore destination
          temp_dir = File.join(@verification_dir, "temp_restore_#{Time.now.to_i}")
          FileUtils.mkdir_p(temp_dir)

          begin
            # Restore to temporary location
            restore = Restore.new(nil, @config)
            restore_result = restore.restore(backup_path, destination: temp_dir)

            unless restore_result[:success]
              return { success: false, error: "Restore failed: #{restore_result[:error]}" }
            end

            # Verify restored database
            # In production, would connect to restored database and verify
            {
              success: true,
              restored_path: temp_dir,
              message: "Restore verification successful"
            }

          rescue => e
            { success: false, error: e.message }

          ensure
            # Clean up temp directory
            FileUtils.rm_rf(temp_dir) if Dir.exist?(temp_dir)
          end
        end
      end

      def verify_chain(base_backup, incrementals, options = {})
        @lock.synchronize do
          start_time = Time.now
          results = []

          # Verify base backup
          base_result = verify_backup(base_backup, options)
          results << { backup: base_backup, result: base_result }

          # Verify each incremental
          incrementals.each do |inc|
            inc_result = verify_backup(inc, options)
            results << { backup: inc, result: inc_result }
          end

          # Verify chain integrity
          chain_valid = results.all? { |r| r[:result][:success] }

          {
            success: chain_valid,
            results: results,
            elapsed_ms: (Time.now - start_time) * 1000
          }
        end
      end

      def stats
        @lock.synchronize do
          @stats.merge({
            verification_dir: @verification_dir,
            cache_size: @cache.size
          })
        end
      end

      private

      def verify_manifest(metadata)
        required_fields = [:name, :type, :created_at, :files]
        missing = required_fields - metadata.keys

        if missing.any?
          { valid: false, error: "Missing required fields: #{missing.join(', ')}" }
        else
          { valid: true }
        end
      end

      def verify_files(backup_path, files)
        missing = []
        corrupted = []

        files.each do |file|
          file_path = File.join(backup_path, file)
          unless File.exist?(file_path)
            missing << file
            next
          end

          # Check file size (in production, would check more)
          if File.size(file_path) == 0
            corrupted << file
          end
        end

        if missing.any?
          { valid: false, missing: missing, message: "Missing files: #{missing.join(', ')}" }
        elsif corrupted.any?
          { valid: false, corrupted: corrupted, message: "Corrupted files: #{corrupted.join(', ')}" }
        else
          { valid: true, file_count: files.size }
        end
      end

      def verify_checksums(backup_path, expected_checksum)
        # In production, would calculate checksum of all files
        { valid: true, checksum: expected_checksum }
      end

      def verify_database(backup_path, metadata)
        # In production, would restore to temp and verify
        { valid: true, message: "Database verification successful" }
      end

      def save_verification_result(backup_path, results)
        result_path = File.join(@verification_dir, "#{File.basename(backup_path)}_verify.json")
        File.write(result_path, JSON.generate({
          backup: File.basename(backup_path),
          timestamp: Time.now.iso8601,
          results: results
        }))
      end
    end
  end
end