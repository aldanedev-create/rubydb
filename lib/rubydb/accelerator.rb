# frozen_string_literal: true

require_relative "accelerator/error"
require_relative "accelerator/manager"
require_relative "accelerator/client"

module RubyDB
  # Optional performance accelerator. The Ruby implementation remains the
  # source of truth; this client only delegates explicitly supported, pure
  # read or utility operations to a managed Go worker.
  module Accelerator
  end
end
