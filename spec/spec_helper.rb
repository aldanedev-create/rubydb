# frozen_string_literal: true

require "fileutils"

if ENV["RUBYDB_COVERAGE"] == "1"
  require "simplecov"
  SimpleCov.start do
    enable_coverage :branch
    minimum_coverage line: 25, branch: 20
  end
end

require_relative "../lib/rubydb"
