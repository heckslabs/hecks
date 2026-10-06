require "spec_helper"
require "json"

# The JavaScript client in packages/hecks-client is released together with the
# gem, so its version is **checked, not remembered**: a bump of
# `lib/hecks/version.rb` fails here until the package manifest (and its
# lockfile's own record of the root package) says the same thing.
RSpec.describe "packages/hecks-client version" do
  let(:package_dir) { File.expand_path("../packages/hecks-client", __dir__) }
  let(:manifest) { JSON.parse(File.read(File.join(package_dir, "package.json"))) }
  let(:lockfile) { JSON.parse(File.read(File.join(package_dir, "package-lock.json"))) }

  it "carries the same version as Hecks::VERSION" do
    expect(manifest.fetch("version")).to eq(Hecks::VERSION),
                                         "packages/hecks-client/package.json says #{manifest.fetch("version")} but " \
                                         "Hecks::VERSION is #{Hecks::VERSION} — bump the package with " \
                                         "`npm version #{Hecks::VERSION} --no-git-tag-version` in packages/hecks-client"
  end

  it "records that version in its lockfile too" do
    expect(lockfile.fetch("version")).to eq(Hecks::VERSION)
    expect(lockfile.fetch("packages").fetch("").fetch("version")).to eq(Hecks::VERSION)
  end

  it "is a public package named @hecks/client" do
    expect(manifest.fetch("name")).to eq("@hecks/client")
    expect(manifest.fetch("private")).to be(false)
  end
end
