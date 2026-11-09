require "spec_helper"
require "hecks/hecks/adapters/site_toolchain"

# A check's network failure is reported on its line; a TLS failure needs OpenSSL, which the prober
# does not load with its file and never requires while another error is propagating.
RSpec.describe Hecks::Adapters::SiteToolchain::Prober do
  it "rescues the network failures it names without OpenSSL", :aggregate_failures do
    expect(described_class::NETWORK).to include(SystemCallError, Timeout::Error, SocketError)
    expect(described_class::NETWORK).not_to include(StandardError)
  end

  it "recognises a TLS failure once OpenSSL is loaded", :aggregate_failures do
    require "openssl"

    expect(described_class.tls_failure?(OpenSSL::SSL::SSLError.new("handshake"))).to be(true)
    expect(described_class.tls_failure?(ArgumentError.new("not tls"))).to be(false)
  end

  it "requires nothing to answer" do
    allow(described_class).to receive(:require)

    described_class.tls_failure?(RuntimeError.new("any"))

    expect(described_class).not_to have_received(:require)
  end
end
