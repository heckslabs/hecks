require "spec_helper"

# Attaching a framework member loads its sibling wiring. Privacy's Deployment-role command
# needs Governance, and the member's ports file carries no `attaches`, so before the loader read
# framework.hecksagon a domain attaching Privacy was refused at boot as ungoverned.
RSpec.describe "a domain attaching the Privacy framework member" do
  PRIVACY_ATTACH = File.expand_path("fixtures/privacy_attach", __dir__).freeze

  it "boots, with Privacy's Governance wiring loaded" do
    expect { Hecks.boot(PRIVACY_ATTACH, install_driving: false) }.not_to raise_error
  end
end
