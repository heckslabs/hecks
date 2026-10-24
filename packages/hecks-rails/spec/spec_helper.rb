ENV["RAILS_ENV"] = "test"

require "rails"
require "action_controller/railtie"
require "rack/test"
require "hecks/rails"
require "hecks/rails/rspec"
require_relative "support/ledger_app"

RSpec.configure do |config|
  config.include Rack::Test::Methods, type: :request
  config.expect_with(:rspec) { |expectations| expectations.syntax = :expect }
end
