# frozen_string_literal: true

module RubyDB
  module Protocol
    class Capabilities
      COMPRESSION = 0x0001
      ENCRYPTION = 0x0002
      PIPELINING = 0x0004
      BATCHING = 0x0008
      PREPARED_STATEMENTS = 0x0010
      CURSORS = 0x0020
      NOTIFICATIONS = 0x0040
      LISTEN_NOTIFY = 0x0080
      LARGE_OBJECTS = 0x0100
      COPY = 0x0200
      TRANSACTIONS = 0x0400
      SAVEPOINTS = 0x0800
      TWO_PHASE_COMMIT = 0x1000
      SECURE_CONNECTION = 0x2000
      LOAD_BALANCING = 0x4000
      AUTO_RECONNECT = 0x8000

      attr_reader :supported, :enabled, :negotiated, :features, :limits

      def initialize
        @supported = 0
        @enabled = 0
        @negotiated = 0
        @limits = {}
        @features = {}
      end

      def set_supported(flags)
        @supported |= flags
      end

      def enable(flags)
        return unless (@supported & flags) == flags
        @enabled |= flags
      end

      def disable(flags)
        @enabled &= ~flags
      end

      def has?(flags)
        (@enabled & flags) == flags
      end

      def supported?(flags)
        (@supported & flags) == flags
      end

      def negotiate(client_capabilities)
        negotiated = client_capabilities & @supported
        @negotiated = negotiated
        @enabled = negotiated

        @features[:compression] = has?(COMPRESSION)
        @features[:encryption] = has?(ENCRYPTION)
        @features[:pipelining] = has?(PIPELINING)
        @features[:batching] = has?(BATCHING)
        @features[:prepared_statements] = has?(PREPARED_STATEMENTS)
        @features[:cursors] = has?(CURSORS)
        @features[:notifications] = has?(NOTIFICATIONS)
        @features[:listen_notify] = has?(LISTEN_NOTIFY)
        @features[:large_objects] = has?(LARGE_OBJECTS)
        @features[:copy] = has?(COPY)
        @features[:transactions] = has?(TRANSACTIONS)
        @features[:savepoints] = has?(SAVEPOINTS)
        @features[:two_phase_commit] = has?(TWO_PHASE_COMMIT)
        @features[:secure_connection] = has?(SECURE_CONNECTION)
        @features[:load_balancing] = has?(LOAD_BALANCING)
        @features[:auto_reconnect] = has?(AUTO_RECONNECT)

        @negotiated
      end

      def set_limit(name, value)
        @limits[name] = value
      end

      def get_limit(name)
        @limits[name]
      end

      def to_hash
        {
          supported: @supported,
          enabled: @enabled,
          negotiated: @negotiated,
          features: @features,
          limits: @limits
        }
      end

      def self.default_server
        caps = new
        caps.set_supported(
          COMPRESSION | ENCRYPTION | PIPELINING | BATCHING |
          PREPARED_STATEMENTS | CURSORS | NOTIFICATIONS |
          LISTEN_NOTIFY | TRANSACTIONS | SAVEPOINTS |
          TWO_PHASE_COMMIT | LOAD_BALANCING
        )
        caps.set_limit(:max_batch_size, 1000)
        caps.set_limit(:max_rows, 100000)
        caps.set_limit(:max_timeout, 300)
        caps
      end

      def self.default_client
        caps = new
        caps.set_supported(
          COMPRESSION | ENCRYPTION | PIPELINING | BATCHING |
          PREPARED_STATEMENTS | CURSORS | TRANSACTIONS |
          SAVEPOINTS | AUTO_RECONNECT
        )
        caps.set_limit(:batch_size, 100)
        caps.set_limit(:max_rows, 10000)
        caps.set_limit(:timeout, 30)
        caps
      end
    end
  end
end