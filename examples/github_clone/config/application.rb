require_relative "boot"
require "rails"
require "active_record/railtie"
require "action_controller/railtie"
require "action_view/railtie"

Bundler.require(*Rails.groups)

module RubyDBGitHubClone
  class Application < Rails::Application
    config.load_defaults 7.2
    config.eager_load = false
    config.secret_key_base = "tiny-rubydb-github-clone-development-secret"
    config.active_record.migration_error = false
  end
end
