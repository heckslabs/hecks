# The gem's entry point: `gem "hecks-rails"` requires it, as Bundler falls back to `hecks/rails`
# for a dashed name. It loads the adapter and, inside a Rails app, the Railtie that boots the
# app's domain.
require_relative "rails/booting"
require_relative "rails/model"
require_relative "rails/routes"
require_relative "rails/controller"
require_relative "rails/form_helper"
require_relative "rails/railtie" if defined?(Rails::Railtie)
