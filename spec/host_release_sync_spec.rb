require "spec_helper"

# The Rust host reports the Hecks release it was built for from `rust/host/HECKS_RELEASE`, and the
# committed-approval gate compares a rehearsal's host_version against it. The file is **checked,
# not remembered**: a bump of `lib/hecks/version.rb` fails here until the file says the same.
RSpec.describe "rust/host/HECKS_RELEASE" do
  let(:file) { File.expand_path("../rust/host/HECKS_RELEASE", __dir__) }

  it "carries the same version as Hecks::VERSION" do
    expect(File.read(file).strip).to eq(Hecks::VERSION),
                                     "rust/host/HECKS_RELEASE says #{File.read(file).strip} but " \
                                     "Hecks::VERSION is #{Hecks::VERSION} — write the release into it"
  end

  it "is the release Ruby's approval gate compares against" do
    require "hecks/ports/persistence/plugins/era"

    expect(Hecks::Translation::ApprovalFile::HOST_RELEASE).to eq(File.read(file).strip)
  end
end
