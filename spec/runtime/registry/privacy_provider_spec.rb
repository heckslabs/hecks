require "spec_helper"

# Boot, a handle's masking and the cryptoshred reach the Privacy bluebook through what it
# provides, not through its name, so the verbs they dispatch are the ones the bluebook declares.
RSpec.describe "privacy and subject_keys capabilities" do
  let(:privacy) { Hecks::Framework.declaration("Privacy") }

  it "is provided by the Privacy bluebook, found by declaration", :aggregate_failures do
    expect(Hecks::Framework.providers_of(Hecks::Bluebook::Capabilities::PRIVACY)).to eq(["Privacy"])
    expect(Hecks::Framework.providers_of(Hecks::Bluebook::Capabilities::SUBJECT_KEYS)).to eq(["Privacy"])
  end

  it "resolves each verb to a command or query the bluebook declares", :aggregate_failures do
    expect(privacy.provided_verb("privacy", :mark_sensitive)).to eq("Privacy::Marking.Mark")
    expect(privacy.provided_verb("privacy", :markings_for)).to eq("Privacy::Marking.ForDomain")
    expect(privacy.provided_verb("subject_keys", :key_for)).to eq("Privacy::SubjectKey.ForSubject")
    expect(privacy.provided_verb("subject_keys", :shred)).to eq("Privacy::SubjectKey.Shred")
  end

  it "finds no provider in a registry that loaded none" do
    expect(Hecks::Runtime::Registry.new(root: Dir.mktmpdir).provider_of("privacy")).to be_nil
  end
end
