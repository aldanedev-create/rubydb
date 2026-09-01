# lib/rubydb/concurrency.rb
# frozen_string_literal: true

require "etc"

# Main entry point for Concurrency module
require_relative "concurrency/scheduler"
require_relative "concurrency/latch"
require_relative "concurrency/mutex"
require_relative "concurrency/rw_lock"
require_relative "concurrency/deadlock_detector"
require_relative "concurrency/lock_graph"
require_relative "concurrency/worker_pool"

module RubyDB
  module Concurrency
    # All classes are now loaded
  end
end