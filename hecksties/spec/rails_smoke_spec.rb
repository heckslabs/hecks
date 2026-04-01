# = Rails Smoke Spec
#
# Boots the pizzas_rails example app as a real subprocess and runs HTTP
# smoke tests against it. Verifies the app starts cleanly and responds
# to basic requests without 5xx errors.
#
# Tagged :slow — excluded from the default sub-second RSpec run.
# Run explicitly:
#   bundle exec rspec hecksties/spec/rails_smoke_spec.rb --tag slow

require "spec_helper"
require "net/http"
require "uri"
require_relative "support/server_helpers"

RAILS_APP_ROOT = File.expand_path("../../examples/pizzas_rails", __dir__)

RSpec.describe "Rails example app smoke test", :slow do
  before(:all) do
    skip "pizzas_rails not found" unless Dir.exist?(RAILS_APP_ROOT)
    @port = free_port
    env = { "PORT" => @port.to_s, "RAILS_ENV" => "test" }
    @pid = spawn(env, "bundle", "exec", "bin/rails", "server",
                 chdir: RAILS_APP_ROOT, out: "/dev/null", err: "/dev/null")
    wait_for_server("http://localhost:#{@port}/up")
    @base = "http://localhost:#{@port}"
  end

  after(:all) do
    Process.kill("TERM", @pid) rescue nil
    Process.wait(@pid) rescue nil if @pid
  end

  it "boots and responds to health check" do
    res = Net::HTTP.get_response(URI("#{@base}/up"))
    expect(res.code.to_i).to eq(200)
  end

  it "serves root without a 5xx crash" do
    res = Net::HTTP.get_response(URI("#{@base}/"))
    expect(res.code.to_i).to be < 500
  end

  # Tier 2 — pending until scaffold routes land

  it "GET /pizzas returns 200" do
    pending "scaffold routes not yet wired"
    res = Net::HTTP.get_response(URI("#{@base}/pizzas"))
    expect(res.code.to_i).to eq(200)
  end

  it "GET /pizzas/new returns 200" do
    pending "scaffold routes not yet wired"
    res = Net::HTTP.get_response(URI("#{@base}/pizzas/new"))
    expect(res.code.to_i).to eq(200)
  end

  it "POST /pizzas with valid params redirects" do
    pending "scaffold routes not yet wired"
    res = Net::HTTP.post_form(URI("#{@base}/pizzas"),
                              "pizza[name]" => "Margherita",
                              "pizza[description]" => "Classic tomato and mozzarella")
    expect(res.code.to_i).to be_between(200, 399)
  end

  it "POST /pizzas with invalid params returns 422" do
    pending "scaffold routes not yet wired"
    res = Net::HTTP.post_form(URI("#{@base}/pizzas"), {})
    expect(res.code.to_i).to eq(422)
  end

  it "GET /pizzas/:id returns 200" do
    pending "scaffold routes not yet wired"
    res = Net::HTTP.get_response(URI("#{@base}/pizzas/1"))
    expect(res.code.to_i).to eq(200)
  end

  it "GET /pizzas/:id/edit returns 200" do
    pending "scaffold routes not yet wired"
    res = Net::HTTP.get_response(URI("#{@base}/pizzas/1/edit"))
    expect(res.code.to_i).to eq(200)
  end

  it "PATCH /pizzas/:id updates a pizza" do
    pending "scaffold routes not yet wired"
    uri = URI("#{@base}/pizzas/1")
    req = Net::HTTP::Patch.new(uri)
    req.set_form_data("pizza[name]" => "Updated Pizza")
    res = Net::HTTP.start(uri.host, uri.port) { |h| h.request(req) }
    expect(res.code.to_i).to be_between(200, 399)
  end

  it "DELETE /pizzas/:id removes a pizza" do
    pending "scaffold routes not yet wired"
    uri = URI("#{@base}/pizzas/1")
    req = Net::HTTP::Delete.new(uri)
    res = Net::HTTP.start(uri.host, uri.port) { |h| h.request(req) }
    expect(res.code.to_i).to be_between(200, 399)
  end
end
