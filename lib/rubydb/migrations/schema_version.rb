# frozen_string_literal: true

require "time"
require "json"

module RubyDB
  module Migrations
    # SchemaVersion - Tracks schema version information
    class SchemaVersion
      attr_reader :version, :applied_at, :migration_name
      attr_reader :description, :author, :checksum

      def initialize(version, migration_name, options = {})
        @version = version
        @migration_name = migration_name
        @description = options[:description] || ""
        @author = options[:author]
        @applied_at = Time.now
        @checksum = options[:checksum]
        @metadata = options[:metadata] || {}
        @status = :applied
        @database_version = options[:database_version]
      end

      def to_hash
        {
          version: @version,
          migration_name: @migration_name,
          description: @description,
          author: @author,
          applied_at: @applied_at.iso8601,
          checksum: @checksum,
          metadata: @metadata,
          status: @status,
          database_version: @database_version
        }
      end

      def to_json
        JSON.generate(to_hash)
      end

      def self.from_json(json_data)
        data = JSON.parse(json_data, symbolize_names: true)
        version = new(
          data[:version],
          data[:migration_name],
          description: data[:description],
          author: data[:author],
          checksum: data[:checksum],
          metadata: data[:metadata] || {},
          database_version: data[:database_version]
        )
        version.instance_variable_set(:@applied_at, Time.parse(data[:applied_at]))
        version.instance_variable_set(:@status, data[:status].to_sym)
        version
      end

      def inspect
        "#<SchemaVersion version=#{@version} migration=#{@migration_name} applied=#{@applied_at}>"
      end
    end
  end
end