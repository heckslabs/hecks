require "spec_helper"
require "hecks/hecks/adapters/desktop_alert"

# The Alerts port's adapter shows one alert through the first notifier the machine has, and opens
# the branch's GitHub runs when clicked; the shell is stood in for, so nothing is shown.
RSpec.describe Hecks::Adapters::DesktopAlert::Alert do
  let(:alert) { described_class.new(title: "shop is ready to deploy", subtitle: "origin/main at abc1234", body: "• Fix", link: "https://github.com/o/shop/actions") }
  let(:shell) { instance_double(Hecks::Adapters::Shell) }

  def ended(status) = Hecks::Adapters::Shell::Result.new("", "", instance_double(Process::Status, exitstatus: status))

  it "shows it through terminal-notifier, opening the link when clicked" do
    called = []
    allow(shell).to receive(:capture) { |*program| called << program and ended(0) }
    alert.show(shell)

    expect(called.first.values_at(0, -2, -1)).to eq(["terminal-notifier", "-open", "https://github.com/o/shop/actions"])
  end

  it "falls back to another program when terminal-notifier is not installed" do
    allow(shell).to receive(:capture).and_return(ended(127), ended(0))
    alert.show(shell)

    expect(shell).to have_received(:capture).twice
  end
end
