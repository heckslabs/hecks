require "tmpdir"
require "open3"

# bin/stores is a SCRIPT, not a library — same reasoning
# project_deploy_contract_spec.rb's own header gives: there's nothing to
# require, so this runs it as a real subprocess (Open3) against a real
# path, the same way bin/project_tenant's own spec does.
#
# Pins the one bug fixed here: a nonexistent domain path used to
# `exit 0` with no output at all, indistinguishable from a domain that
# legitimately has zero aggregates.
RSpec.describe "bin/stores" do
  # BIN_STORES_SCRIPT, not a bare SCRIPT — see word_coverage_spec.rb's own
  # comment on InMemoryDomain::ROOT: a bare top-level constant collides
  # with another spec file's identical name (project_tenant_spec.rb
  # already claims SCRIPT), caught by load_hygiene_spec.rb's "no two spec
  # files disagree about a top-level constant" gate.
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
    _stdout, _stderr, status = Open3.capture3(BIN_STORES_SCRIPT)

    expect(status).not_to be_success
  end
end
