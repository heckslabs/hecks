require "tmpdir"
require "open3"
require "rbconfig"

# Runs `exe/hecks stores` as a subprocess.
# Pins that a nonexistent domain path fails loudly instead of exiting 0 silently.
RSpec.describe "hecks stores" do
  # Uniquely named: load_hygiene_spec.rb rejects top-level constants that collide across specs.
  STORES_LAUNCHER = File.join(InMemoryDomain::ROOT, "exe/hecks").freeze

  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      example.run
    end
  end

  it "exits non-zero with a clear message for a nonexistent domain path", :aggregate_failures do
    missing = File.join(@dir, "no-such-domain")
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, STORES_LAUNCHER, "stores", missing)

    expect(status).not_to be_success
    expect(stdout).to eq("")
    expect(stderr).to include(missing)
  end

  it "requires a domain argument at all", :aggregate_failures do
    _stdout, stderr, status = Open3.capture3(RbConfig.ruby, STORES_LAUNCHER, "stores")

    expect(status).not_to be_success
    expect(stderr).to include("usage:")
    expect(stderr).not_to include("IndexError")
  end
end
