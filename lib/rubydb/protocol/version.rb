# frozen_string_literal: true

module RubyDB
  module Protocol
    # ProtocolVersion - Defines protocol versions and compatibility
    class ProtocolVersion
      MAJOR = 1
      MINOR = 0
      PATCH = 0

      VERSION_STRING = "#{MAJOR}.#{MINOR}.#{PATCH}"
      VERSION_INT = (MAJOR << 16) | (MINOR << 8) | PATCH

      # Supported protocol versions
      SUPPORTED_VERSIONS = {
        0x010000 => "1.0.0",
        0x010001 => "1.0.1"
      }

      def self.current
        VERSION_INT
      end

      def self.current_string
        VERSION_STRING
      end

      def self.supported?(version)
        SUPPORTED_VERSIONS.key?(version)
      end

      def self.parse(version_string)
        parts = version_string.split(".").map(&:to_i)
        return nil if parts.size != 3
        (parts[0] << 16) | (parts[1] << 8) | parts[2]
      end

      def self.to_string(version_int)
        major = (version_int >> 16) & 0xFF
        minor = (version_int >> 8) & 0xFF
        patch = version_int & 0xFF
        "#{major}.#{minor}.#{patch}"
      end

      def self.compatible?(client_version, server_version)
        # Major version must match
        return false if (client_version >> 16) != (server_version >> 16)
        # Minor version: server must support client's minor version
        return false if (client_version & 0xFF00) > (server_version & 0xFF00)
        true
      end
    end
  end
end