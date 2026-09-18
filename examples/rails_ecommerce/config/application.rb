# frozen_string_literal: true

require_relative "boot"
require "rails"
require "active_record/railtie"
require "action_controller/railtie"
require "action_view/railtie"

Bundler.require(*Rails.groups)

module RubyDBRailsEcommerce
  class Application < Rails::Application
    config.load_defaults 7.2
    config.eager_load = false
    config.secret_key_base = "rubydb-rails-ecommerce-development-secret"
    config.consider_all_requests_local = true
    # Run migrations explicitly in this small example. It keeps Rails from
    # opening a second embedded connection while the app is booting.
    config.active_record.migration_error = false
  end
end
