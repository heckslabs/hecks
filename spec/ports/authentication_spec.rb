require "hecksagain"

RSpec.describe Hecksagain::Ports::Authentication do
  def registry_with(*adapter_paths, &extra)
    registry = Hecksagain::Runtime::Registry.new
    Hecksagain.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Kernel.load(File.expand_path("../../lib/hecksagain/ports/authentication.port", __dir__))
      adapter_paths.each { |path| Kernel.load(path) }
      extra&.call
    end
    registry
  end

  def google_authentication_adapter
    File.expand_path("../../lib/hecksagain/adapters/driven/google_authentication.adapter", __dir__)
  end

  describe "adapter resolution" do
    it "refuses when no adapter implements the port" do
      registry = registry_with

      expect { described_class.authorization_url(registry) }
        .to raise_error(Hecksagain::Runtime::WiringError, /no adapter implements/)
    end

    it "refuses to choose between more than one bound adapter" do
      registry = registry_with(google_authentication_adapter) { Hecks.adapter("AlwaysAuthenticate") { port "authentication" } }

      expect { described_class.authorization_url(registry) }
        .to raise_error(Hecksagain::Runtime::WiringError, /AlwaysAuthenticate, GoogleAuthentication/)
    end
  end

  describe "GoogleAuthentication, the one real adapter" do
    let(:registry) { registry_with(google_authentication_adapter) }

    around do |example|
      original = ENV.to_h.slice("GOOGLE_CLIENT_ID", "GOOGLE_CLIENT_SECRET", "GOOGLE_REDIRECT_URI")
      ENV["GOOGLE_CLIENT_ID"] = "test-client-id"
      ENV["GOOGLE_CLIENT_SECRET"] = "test-client-secret"
      ENV["GOOGLE_REDIRECT_URI"] = "http://localhost:4567/auth/google/callback"
      example.run
    ensure
      %w[GOOGLE_CLIENT_ID GOOGLE_CLIENT_SECRET GOOGLE_REDIRECT_URI].each { |key| ENV[key] = original[key] }
    end

    it "builds a real Google authorization URL, carrying a fresh state" do
      url, state = described_class.authorization_url(registry)

      expect(url).to start_with("https://accounts.google.com/o/oauth2/v2/auth?")
      expect(url).to include("client_id=test-client-id")
      expect(url).to include("redirect_uri=#{ERB::Util.url_encode('http://localhost:4567/auth/google/callback')}")
      expect(url).to include("scope=openid%20email%20profile")
      expect(url).to include("state=#{state}")
      expect(state).to match(/\A[0-9a-f]{48}\z/)
    end

    it "refuses a state mismatch before ever reaching Google, with no network call" do
      expect { described_class.verify(registry, code: "irrelevant", state: "wrong", expected_state: "right") }
        .to raise_error(Hecksagain::Ports::Authentication::ValidationError, "state mismatch")
    end

    it "refuses with no code/state at all the same way" do
      expect { described_class.verify(registry, code: "x", state: nil, expected_state: "right") }
        .to raise_error(Hecksagain::Ports::Authentication::ValidationError, "state mismatch")
    end
  end
end
