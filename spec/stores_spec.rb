require "tmpdir"
require "open3"
require "rbconfig"

# Runs `exe/hecks stores` as a subprocess.
# Pins that a nonexistent domain path fails loudly instead of exiting 0 silently.
RSpec.describe "hecks stores" do
  # Uniquely named: load_hygiene_spec.rb rejects top-level constants that collide across specs.
  STORES_LAUNCHER = File.join(InMemoryDomain::ROOT, "exe/hecks").freeze

  scratch_directory

  it "exits non-zero with a clear message for a nonexistent domain path", :aggregate_failures, :process do
    missing = File.join(@dir, "no-such-domain")
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, STORES_LAUNCHER, "stores", missing)

    expect(status).not_to be_success
    expect(stdout).to eq("")
    expect(stderr).to include(missing)
  end

  # A one-bluebook domain with no local files, so every aggregate is in Memory.
  def memory_domain
    FileUtils.mkdir_p(File.join(@dir, "bluebook"))
    FileUtils.cp(File.join(InMemoryDomain::ROOT, "spec/fixtures/deciderate.bluebook"), File.join(@dir, "bluebook"))
    @dir
  end

  def run_command(*words) = Open3.capture3(RbConfig.ruby, STORES_LAUNCHER, *words)

  { "stores" => ->(dir) { dir }, "introspection.stores" => ->(dir) { "domain.value=#{dir}" },
    "introspection.history" => ->(dir) { "domain.value=#{dir}" } }.each do |command, argument|
    it "says on stderr that nothing is persisted and how to opt in, for hecks #{command}", :aggregate_failures, :process do
      stdout, stderr, status = run_command(command, argument.call(memory_domain), "--wait")

      expect(status).to be_success
      expect(JSON.parse(stdout)).to be_a(Hash)
      expect(stderr).to include("nothing is persisted").and include("hecks.local.hecksagon")
    end
  end

  it "requires a domain argument at all", :aggregate_failures, :process do
    _stdout, stderr, status = Open3.capture3(RbConfig.ruby, STORES_LAUNCHER, "stores")

    expect(status).not_to be_success
    expect(stderr).to include("usage:")
    expect(stderr).not_to include("IndexError")
  end
end
