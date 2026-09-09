# frozen_string_literal: true

require_relative "boot"
require "rails"
require "active_record/railtie"
require "action_controller/railtie"
require "action_view/railtie"

Bundler.require(*Rails.groups)

module RubyDBRailsExample
  class Application < Rails::Application
    config.load_defaults 7.2
    config.eager_load = false
    config.secret_key_base = "rubydb-rails-example-development-secret"
    config.consider_all_requests_local = true
    # Embedded RubyDB intentionally allows one engine owner per process. Rails'
    # development pending-migration middleware opens a second temporary pool,
    # so run `bin/rails db:migrate` explicitly for this example.
    config.active_record.migration_error = false
  end
end
