# = Hecks::Conventions::RouteContract
#
# Single source of truth for URL patterns used by Ruby and Go generators
# and the smoke test. Eliminates divergent route definitions and the
# fallback heuristic in form_submission.rb.
#
#   RouteContract.form_path("pizzas", "create_pizza")    # => "/pizzas/create_pizza/new"
#   RouteContract.submit_path("pizzas", "create_pizza")  # => "/pizzas/create_pizza/submit"
#   RouteContract.query_path("pizzas", "by_name")        # => "/pizzas/queries/by_name"
#
module Hecks::Conventions
  # Hecks::Conventions::RouteContract
  #
  # Single source of truth for URL patterns used by Ruby and Go generators and smoke tests.
  #
  module RouteContract
    def self.form_path(plural, cmd_snake)    = "/#{plural}/#{cmd_snake}/new"
    def self.submit_path(plural, cmd_snake)  = "/#{plural}/#{cmd_snake}/submit"
    def self.index_path(plural)              = "/#{plural}"
    def self.show_path(plural)               = "/#{plural}/show"
    def self.query_path(plural, query_snake) = "/#{plural}/queries/#{query_snake}"
    def self.scope_path(plural, scope_name)  = "/#{plural}/scopes/#{scope_name}"
    def self.spec_path(plural, spec_snake)   = "/#{plural}/specifications/#{spec_snake}"
  end
end
