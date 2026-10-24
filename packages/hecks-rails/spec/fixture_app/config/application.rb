require "rails"
require "action_controller/railtie"
require "action_view/railtie"
require "hecks/rails"

# A Rails app with no database: its domain is the Banking chapters in bluebook/, reached through
# the models, controllers and routes `hecks launch.project_rails` wrote.
module FixtureApp
  # The fixture's application: only what a request spec needs.
  class Application < Rails::Application
    config.load_defaults Rails::VERSION::STRING.to_f
    config.root = File.expand_path("..", __dir__)
    config.eager_load = false
    config.consider_all_requests_local = true
    config.action_dispatch.show_exceptions = :none
    config.action_controller.allow_forgery_protection = false
    config.secret_key_base = "fixture-only-secret-key-base"
    config.hosts.clear
    config.logger = Logger.new(nil)
  end
end
