# frozen_string_literal: true

module RubyDB
  module Migrations
    # MigrationVersion - Version management for migrations
    class MigrationVersion
      attr_reader :version, :timestamp, :sequence

      def initialize(version = nil)
        if version
          @version = version
          parse_version
        else
          @timestamp = Time.now
          @sequence = 0
          @version = generate_version
        end
      end

      def parse_version
        if @version =~ /^(\d{14})_(\d+)$/
          @timestamp = Time.strptime($1, "%Y%m%d%H%M%S")
          @sequence = $2.to_i
        else
          @timestamp = Time.now
          @sequence = 0
        end
      end

      def generate_version
        "#{@timestamp.strftime('%Y%m%d%H%M%S')}_#{@sequence}"
      end

      def to_s
        @version
      end

      def to_i
        @version.gsub(/[^0-9]/, "").to_i
      end

      def <=>(other)
        return nil unless other.is_a?(MigrationVersion)
        @timestamp <=> other.timestamp
      end

      def <(other)
        return false unless other.is_a?(MigrationVersion)
        @timestamp < other.timestamp
      end

      def >(other)
        return false unless other.is_a?(MigrationVersion)
        @timestamp > other.timestamp
      end

      def next
        MigrationVersion.new("#{@timestamp.strftime('%Y%m%d%H%M%S')}_#{@sequence + 1}")
      end

      def prev
        return nil if @sequence == 0
        MigrationVersion.new("#{@timestamp.strftime('%Y%m%d%H%M%S')}_#{@sequence - 1}")
      end

      def inspect
        "#<MigrationVersion version=#{@version} timestamp=#{@timestamp}>"
      end
    end
  end
end