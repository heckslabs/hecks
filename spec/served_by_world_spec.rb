require "spec_helper"
require "rack/test"
require "openssl"
require "json"
require_relative "../lib/hecks/served_options"
require_relative "../lib/hecks/quality_control/adapters/github_ci_webhook"

# A `.world` serves a domain through `served_by` lines: the builder takes the verb with no
# change, the route is derived from the adapter's name, and the secret is read from the
# environment variable the line names.
RSpec.describe "served_by in a world" do
  include Rack::Test::Methods

  let(:registry) { Hecks::Runtime::Registry.new }
  let(:secret)   { "served-by-spec-secret" }
  let(:adapters) do
    { "GithubCiWebhook" => Hecks::Adapters::Driving::GithubCiWebhook,
      "GithubWebhook"   => Hecks::Adapters::Driving::GithubWebhook }
  end
  let(:world) do
    Hecks.with_registry(registry) do
      Hecks.world("Served") do
        realm "Examples"
        served_by("GithubCiWebhook") { secret "CI_WEBHOOK_SECRET" }
        served_by("GithubWebhook") do
          secret "OTHER_SECRET"
          path "/hooks/github"
        end
      end
    end
    registry.world("Served")
  end
  let(:app) do
    Hecks::ServedOptions.rack_app(
      world, adapters: adapters, env: { "CI_WEBHOOK_SECRET" => secret, "OTHER_SECRET" => "x" }
    )
  end

  def signed_post(path, body)
    digest = OpenSSL::HMAC.hexdigest(OpenSSL::Digest.new("sha256"), secret, body)
    post path, body, "HTTP_X_HUB_SIGNATURE_256" => "sha256=#{digest}", "HTTP_X_GITHUB_EVENT" => "ping"
  end

  it "records each line under its adapter, so two lines do not overwrite each other" do
    expect(Hecks::ServedOptions.entries(world).map { |e| e[:adapter] })
      .to contain_exactly("GithubCiWebhook", "GithubWebhook")
  end

  it "derives the route from the adapter's name, and lets `path` override it" do
    paths = Hecks::ServedOptions.entries(world).to_h { |e| [e[:adapter], e[:path]] }
    expect(paths).to eq("GithubCiWebhook" => "/webhooks/github_ci_webhook", "GithubWebhook" => "/hooks/github")
  end

  it "answers a correctly signed request at the derived path" do
    signed_post("/webhooks/github_ci_webhook", "{}")
    expect(last_response.status).to eq(200)
  end

  it "refuses a request signed with another secret" do
    post "/webhooks/github_ci_webhook", "{}", "HTTP_X_HUB_SIGNATURE_256" => "sha256=bad", "HTTP_X_GITHUB_EVENT" => "ping"
    expect(last_response.status).to eq(401)
  end

  it "refuses to boot when the named secret variable is unset" do
    expect { Hecks::ServedOptions.rack_app(world, adapters: adapters, env: {}) }
      .to raise_error(ArgumentError, /CI_WEBHOOK_SECRET is not set/)
  end
end
