# frozen_string_literal: true

require "rails"
require "active_record"

$LOAD_PATH.unshift(File.expand_path("../../../../lib", __dir__))
$LOAD_PATH.unshift(File.expand_path("../../../../adapters/activerecord/lib", __dir__))

require "rubydb"
require "active_record/connection_adapters/rubydb_adapter"

module RubydbRailsSmoke
  class Application < Rails::Application
    config.eager_load = false
    config.secret_key_base = "rubydb-rails-smoke-test-secret"
  end
end
