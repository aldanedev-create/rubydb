# frozen_string_literal: true

module RubyDB
  module BuildInfo
    VERSION = RubyDB::VERSION if defined?(RubyDB::VERSION)

    def self.to_h
      {
        version: (defined?(RubyDB::VERSION) ? RubyDB::VERSION : "unknown"),
        ruby: RUBY_VERSION,
        platform: RUBY_PLATFORM
      }
    end
  end
end
