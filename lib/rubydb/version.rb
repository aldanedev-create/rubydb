# frozen_string_literal: true

# RubyDB version information
# Follows Semantic Versioning (SemVer) 2.0.0
# See: https://semver.org/

module RubyDB
  # Current version of RubyDB
  #
  # Format: MAJOR.MINOR.PATCH
  # - MAJOR: Incompatible API changes
  # - MINOR: Backwards-compatible new functionality
  # - PATCH: Backwards-compatible bug fixes
  VERSION = "0.1.0"

  # Version components for easy access
  module Version
    MAJOR = 0
    MINOR = 1
    PATCH = 0
    PRE = nil  # e.g., "alpha", "beta", "rc1"

    def self.to_s
      [MAJOR, MINOR, PATCH].join(".")
    end

    def self.full
      version = to_s
      version += "-#{PRE}" if PRE
      version
    end
  end
end