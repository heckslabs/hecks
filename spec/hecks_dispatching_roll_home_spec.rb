require "spec_helper"
require "tmpdir"
require_relative "support/roll_forward_fixtures"

# A dispatch runs in the Hecks checkout, whatever repository the session that heard the roll
# stands in.
RSpec.describe "a roll heard from another repository's directory" do
  include RollForwardFixtures

  let(:checkout) { Hecks::Adapters::Dispatching::Checkout }
  let(:launcher) { Hecks::Adapters::Dispatching::Launcher }

  around do |example|
    Dir.mktmpdir do |dir|
      @elsewhere = File.realpath(dir)
      system("git", "-C", @elsewhere, "init", "-q", out: File::NULL, exception: true)
      example.run
    end
  end

  before { Hecks::Adapters::Dispatching::LastRoll.reset! }

  it "names the Hecks checkout from where its code lives" do
    expect(checkout.home).to eq(checkout.main(File.expand_path("..", __dir__)))
  end

  it "fills into the Hecks checkout, not the repository the session stands in", :aggregate_failures do
    allow(launcher).to receive(:new).and_call_original
    allow(Dir).to receive(:pwd).and_return(@elsewhere)
    rolling({}).roll

    expect(launcher).to have_received(:new).with(checkout.home, anything).at_least(:once)
    expect(launcher).not_to have_received(:new).with(@elsewhere, anything)
  end
end
