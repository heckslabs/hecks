require "spec_helper"

# The README's version line is **checked, not remembered**. A version bump edits
# `lib/hecks/version.rb` and nothing else forces the prose to follow, so every
# "Current release: `x.y.z`" in the README must equal `Hecks::VERSION`. A release
# that bumps the constant fails here until the README says the same thing.
RSpec.describe "README current-release claims" do
  let(:readme) { File.read(File.expand_path("../README.md", __dir__)) }
  let(:claimed) { readme.scan(/Current release: `([^`]+)`/).flatten }

  it "states the current release in both the Status line and the Project status section" do
    expect(claimed.size).to be >= 2, "expected 'Current release: `x.y.z`' in both places"
  end

  it "matches Hecks::VERSION everywhere it is stated" do
    stale = claimed.reject { |version| version == Hecks::VERSION }

    expect(stale).to be_empty,
                     "README says #{stale.uniq.join(', ')} but Hecks::VERSION is " \
                     "#{Hecks::VERSION} — update every 'Current release:' line in README.md"
  end
end
