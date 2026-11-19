require "spec_helper"
require "tmpdir"
require "hecks/hecks/adapters/red_wake_weighing"
require_relative "support/red_wake_repository"

# What a red-main wake is weighed by, read from a scratch repository: no flag, a standing flag
# with the run a session for it takes, and a linked worktree, which never reads the marker.
RSpec.describe Hecks::Adapters::RedWakeWeighing do
  include RedWakeRepository

  let(:scratch) { File.realpath(Dir.mktmpdir("red-wake")) }

  before { open_repository }

  after { FileUtils.remove_entry(scratch) }

  it "weighs a main with no flag as not standing" do
    expect(described_class.new(repo).facts).to include(standing: false, main_checkout: true, run: { value: "" })
  end

  it "weighs a standing flag with the run a session for it takes" do
    run = flag!("e5e5e5e5e5e5e5")
    expect(described_class.new(repo).facts).to include(standing: true, flag: { value: "flag-e5e5e5e5e5" }, run: { value: run })
  end

  it "weighs a linked worktree as not the main checkout, without reading the flag" do
    flag!("f6f6f6f6f6f6f6")
    git("worktree", "add", "-q", "-b", "side", File.join(scratch, "side"))
    expect(described_class.new(File.join(scratch, "side")).facts).to include(standing: false, main_checkout: false)
  end
end
