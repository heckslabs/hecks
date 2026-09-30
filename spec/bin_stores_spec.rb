require "tmpdir"
require "open3"

# Runs bin/stores as a subprocess; it is a script with nothing to require.
# Pins that a nonexistent domain path fails loudly instead of exiting 0 silently.
RSpec.describe "bin/stores" do
  # Uniquely named: load_hygiene_spec.rb rejects top-level constants that collide across specs.
  BIN_STORES_SCRIPT = File.join(InMemoryDomain::ROOT, "bin/stores").freeze

  it "exits non-zero with a clear message for a nonexistent domain path" do
    Dir.mktmpdir do |dir|
      missing = File.join(dir, "no-such-domain")

      stdout, stderr, status = Open3.capture3(BIN_STORES_SCRIPT, missing)

      expect(status).not_to be_success
      expect(stdout).to eq("")
      expect(stderr).to include(missing)
    end
  end

  it "requires a domain argument at all" do
    _stdout, stderr, status = Open3.capture3(BIN_STORES_SCRIPT)

    expect(status).not_to be_success
    expect(stderr).to include("usage:")
    expect(stderr).not_to include("IndexError")
  end
end
