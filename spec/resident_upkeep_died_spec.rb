require "spec_helper"
require "tmpdir"
require "hecks/adapters/driving/resident/server"

# A resident's upkeep watches the code and the checkout between lines. An upkeep that raises
# cannot watch them any longer, so the resident retires and leaves a note naming the error: the
# next launcher starts one from the code as it now is, never a resident serving stale code.
RSpec.describe "a resident whose upkeep fails" do
  let(:paths) { Hecks::Adapters::Driving::Resident::Paths }
  let(:server) { Hecks::Adapters::Driving::Resident::Server.new("/checkout", "/checkout/exe/hecks") }
  let(:fingerprint) { instance_double(Hecks::Adapters::Driving::Resident::Fingerprint) }
  let(:listener) { instance_double(UNIXServer, closed?: false, close: nil) }

  around do |example|
    Dir.mktmpdir("hru") do |dir|
      saved = ENV.fetch("HECKS_CACHE_DIR", nil)
      ENV["HECKS_CACHE_DIR"] = dir
      FileUtils.mkdir_p(paths.directory)
      example.run
    ensure
      ENV["HECKS_CACHE_DIR"] = saved
    end
  end

  def failed_upkeep
    allow(fingerprint).to receive(:changed?).and_raise(IOError, "the disk went away")
    server.instance_variable_set(:@fingerprint, fingerprint)
    server.instance_variable_set(:@server, listener)
    server.send(:upkeep)
  end

  it "retires the resident and notes the error that ended the upkeep", :aggregate_failures do
    failed_upkeep
    expect(server.instance_variable_get(:@retired)).to be(true)
    expect(File.read(paths.upkeep_died("/checkout"))).to include("IOError: the disk went away")
  end

  it "closes the socket it listened on, so no caller reaches it" do
    failed_upkeep
    expect(listener).to have_received(:close)
  end
end
