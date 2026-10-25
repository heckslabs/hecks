# A Rails app over the Ledger fixture domain. Its root holds `bluebook/` and `bluebook.yml`, so
# the railtie boots it and generates a model for each aggregate without one of its own.
class LedgerApp < Rails::Application
  config.root = File.expand_path("../fixtures/ledger", __dir__)
  config.eager_load = false
  config.secret_key_base = "a" * 64
  config.hosts.clear
  config.logger = Logger.new(nil)
  config.action_controller.allow_forgery_protection = false
end

LedgerApp.initialize!

require_relative "accounts_controller"
require_relative "notes_controller"

LedgerApp.routes.draw do
  resources :accounts
  resources :notes
end
