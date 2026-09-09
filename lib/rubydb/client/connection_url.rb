# frozen_string_literal: true

require "uri"

module RubyDB
  module Client
    # Parses RubyDB's own connection URL format. This is deliberately not a
    # PostgreSQL URL parser: RubyDB speaks its framed RubyDB protocol.
    module ConnectionURL
      SUPPORTED_SCHEMES = %w[rubydb rubydbs].freeze

      module_function

      def parse(value)
        raise ArgumentError, "RubyDB connection URL is required" if value.nil? || value.to_s.empty?

        uri = URI.parse(value.to_s)
        scheme = uri.scheme.to_s.downcase
        raise ArgumentError, "Unsupported RubyDB connection URL scheme" unless SUPPORTED_SCHEMES.include?(scheme)
        raise ArgumentError, "RubyDB connection URL requires a host" if uri.host.nil? || uri.host.empty?

        database = uri.path.to_s.sub(%r{\A/}, "")
        raise ArgumentError, "RubyDB connection URL requires a database name" if database.empty?

        query = URI.decode_www_form(uri.query.to_s).to_h
        ssl_mode = query["sslmode"]&.downcase
        ssl_enabled = scheme == "rubydbs" || boolean(query["ssl"], false) || %w[require verify-ca verify-full].include?(ssl_mode)
        verify_peer = if query.key?("verify_peer")
          boolean(query["verify_peer"], true)
        else
          %w[verify-ca verify-full].include?(ssl_mode) || scheme == "rubydbs"
        end

        ssl = {enabled: true, verify_peer: verify_peer} if ssl_enabled
        if ssl
          ssl[:ca_file] = query["ca_file"] if query["ca_file"]
          ssl[:cert_file] = query["cert_file"] if query["cert_file"]
          ssl[:key_file] = query["key_file"] if query["key_file"]
          ssl[:min_version] = query["min_version"] if query["min_version"]
        end

        result = {
          host: uri.host,
          port: uri.port || 7432,
          username: decode(uri.user),
          password: decode(uri.password),
          database: URI.decode_www_form_component(database),
          ssl: ssl || false
        }
        result[:timeout] = positive_number(query["timeout"], "timeout") if query["timeout"]
        result[:pool_size] = positive_integer(query["pool_size"], "pool_size") if query["pool_size"]
        result[:compress] = boolean(query["compress"], false) if query.key?("compress")
        result[:format] = query["format"].to_sym if query["format"]
        result.compact
      rescue URI::InvalidURIError
        raise ArgumentError, "Invalid RubyDB connection URL"
      end

      def decode(value)
        value && URI.decode_www_form_component(value)
      end
      private_class_method :decode

      def boolean(value, default)
        return default if value.nil?

        case value.to_s.downcase
        when "1", "true", "yes", "on" then true
        when "0", "false", "no", "off" then false
        else raise ArgumentError, "Invalid boolean connection URL option"
        end
      end
      private_class_method :boolean

      def positive_integer(value, name)
        number = Integer(value, 10)
        raise ArgumentError, "#{name} must be positive" unless number.positive?

        number
      rescue ArgumentError
        raise ArgumentError, "Invalid #{name} connection URL option"
      end
      private_class_method :positive_integer

      def positive_number(value, name)
        number = Float(value)
        raise ArgumentError, "#{name} must be positive" unless number.positive?

        number
      rescue ArgumentError
        raise ArgumentError, "Invalid #{name} connection URL option"
      end
      private_class_method :positive_number
    end
  end
end
