require "spec_helper"
require "hecks/extensions/serve/cors_headers"

RSpec.describe Hecks::HTTP::CorsHeaders do
  subject(:host) do
    Class.new { include Hecks::HTTP::CorsHeaders }.new
  end

  around do |example|
    orig_allow_all = ENV.delete("HECKS_ALLOW_ALL_ORIGINS")
    orig_origin    = ENV.delete("HECKS_CORS_ORIGIN")
    example.run
  ensure
    ENV["HECKS_ALLOW_ALL_ORIGINS"] = orig_allow_all if orig_allow_all
    ENV["HECKS_CORS_ORIGIN"]       = orig_origin    if orig_origin
  end

  describe "#cors_origin_value" do
    it "returns '*' when HECKS_ALLOW_ALL_ORIGINS=true" do
      ENV["HECKS_ALLOW_ALL_ORIGINS"] = "true"
      expect(host.cors_origin_value).to eq("*")
    end

    it "returns the configured origin when HECKS_CORS_ORIGIN is set" do
      ENV["HECKS_CORS_ORIGIN"] = "https://example.com"
      expect(host.cors_origin_value).to eq("https://example.com")
    end

    it "returns nil when neither variable is set" do
      expect(host.cors_origin_value).to be_nil
    end
  end

  describe "#apply_cors_origin" do
    let(:res) { {} }

    it "sets the header when a value is present" do
      ENV["HECKS_CORS_ORIGIN"] = "https://app.example.com"
      host.apply_cors_origin(res)
      expect(res["Access-Control-Allow-Origin"]).to eq("https://app.example.com")
    end

    it "does not set the header when no value is configured" do
      host.apply_cors_origin(res)
      expect(res).not_to have_key("Access-Control-Allow-Origin")
    end
  end
end
