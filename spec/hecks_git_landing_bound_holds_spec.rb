require "spec_helper"
require "hecks/hecks/adapters/delivery_library"
Hecks::Adapters::DeliveryLibrary.require("git_landing")
require "hecks/hecks/adapters/red_flagging"
require "hecks/hecks/adapters/boarding_holding"
require "tmpdir"
require "open3"
require_relative "support/landing_holds_registry"

# A throwaway repository whose main is both red-flagged and held for a boarding, with one branch.
module BoundHoldsRepository
  module_function

  def git(*, chdir:)
    out, status = Open3.capture2e("git", "-c", "user.name=t", "-c", "user.email=t@t", *, chdir: chdir)
    raise out unless status.success?

    out
  end

  # @return [String] the repository's main checkout, with branch `feature-x` one commit ahead
  def held(dir)
    repo = File.join(dir, "main")
    FileUtils.mkdir_p(repo)
    git("init", "-b", "main", chdir: repo)
    git("commit", "--allow-empty", "-m", "first", chdir: repo)
    git("worktree", "add", "-b", "feature-x", File.join(dir, "feature-x"), chdir: repo)
    git("commit", "--allow-empty", "-m", "feature", chdir: File.join(dir, "feature-x"))
    hold_and_flag(repo)
  end

  # @return [String] the repository, red-flagged and held for a boarding
  def hold_and_flag(repo)
    Hecks::Adapters::RedFlagging.new(checkout: repo).hoist(commit: "abcdef1234567", detail: "abc: run 7 failure")
    Hecks::Adapters::BoardingHolding.new.mark(checkout: repo, owner: { value: "rehearser" })
    repo
  end
end

# Delivery asks the adapter its project bound to the `Holds` port whether a landing is held; a
# project that binds none has nothing that holds one. Hecks binds the red flag and the boarding
# hold there, and delivery's own Ruby names neither.
RSpec.describe Hecks::Adapters::GitLanding::BoundHolds do
  let(:dir) { Dir.mktmpdir("hecks-bound-holds") }

  after { FileUtils.remove_entry(dir) }

  it "lands under a red flag and a boarding hold when the project binds nothing to Holds" do
    landing = Hecks::Adapters::GitLanding.new(registry: LandingHoldsRegistry::Registry.new({}))
    landed = landing.merge(checkout: BoundHoldsRepository.held(dir), branch: "feature-x")
    expect(landed.dig(:outcome, :value)).to eq("merged")
  end

  it "binds exactly one adapter to the port in Hecks, the pipeline's LandingHolding" do
    bound = boot_hecks_in_memory.registry.adapters.values.select { |adapter| adapter.port == described_class::PORT }
    expect(bound.map(&:name)).to eq(["LandingHolding"])
  end

  it "keeps the pipeline's red flag and boarding hold out of delivery's Ruby" do
    sources = Dir.glob(File.join(Hecks::Adapters::DeliveryLibrary::ROOT, "**", "*.rb")).map { |path| File.read(path) }
    named = sources.grep(%r{RedFlagGuard|BoardingHoldMarker|hecks/hecks/adapters/(red_flag|boarding_hold|git_main_pull)})
    expect(named).to be_empty
  end
end
