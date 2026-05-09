# config.ru — Rack entry-point for the Hecks Studio.
# Booted by `bundle exec rackup config.ru -p 3100`.
require_relative "app"
run StudioApp
