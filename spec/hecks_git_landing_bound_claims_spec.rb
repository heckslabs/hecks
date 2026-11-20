# frozen_string_literal: true

require "spec_helper"
require "hecks/hecks/adapters/delivery_library"
Hecks::Adapters::DeliveryLibrary.require("git_landing")
require "hecks/hecks/adapters/shell"
require "tmpdir"
require "open3"
require_relative "support/landing_claims_registry"

# A throwaway repository whose branch `feature-x` changes `lib/a.rb`.
module BoundClaimsRepository
  module_function

  def git(*, chdir:)
    out, status = Open3.capture2e("git", "-c", "user.name=t", "-c", "user.email=t@t", *, chdir: chdir)
    raise out unless status.success?

    out
  end

  # @return [String] the repository, with branch `feature-x` one file ahead of main
  def build(repo)
    git("init", "-q", "-b", "main", chdir: repo)
    git("commit", "-q", "--allow-empty", "-m", "first", chdir: repo)
    git("checkout", "-q", "-b", "feature-x", chdir: repo)
    change(repo)
    git("checkout", "-q", "main", chdir: repo)
    repo
  end

  def change(repo)
    FileUtils.mkdir_p(File.join(repo, "lib"))
    File.write(File.join(repo, "lib/a.rb"), "a\n")
    git("add", ".", chdir: repo)
    git("commit", "-q", "-m", "a", chdir: repo)
  end

  # @return [Object] a git that takes its arguments without the program name, as `Rivals` calls it
  def adapter
    shell = Hecks::Adapters::Shell.new
    Object.new.tap { |git| git.define_singleton_method(:capture) { |*argv, **opts| shell.capture("git", *argv, **opts) } }
  end
end

# Delivery asks the adapter its project bound to the `Claims` port which claims stand and whether
# one holds a changed file; a project that binds none has no claims. Hecks binds the started Work
# items and its overlap rule there, and delivery's own Ruby names neither.
RSpec.describe Hecks::Adapters::GitLanding::BoundClaims do
  let(:repo) { BoundClaimsRepository.build(File.realpath(Dir.mktmpdir("hecks-bound-claims"))) }
  let(:library) { Hecks::Adapters::DeliveryLibrary::ROOT }

  before { allow(Hecks::Adapters::StartedWork).to receive(:items).and_return([{ key: "other", area: ["lib"] }]) }

  after { FileUtils.remove_entry(repo) }

  def refusal(registry)
    Hecks::Adapters::GitLanding::Rivals.new(BoundClaimsRepository.adapter, repo, registry).refusal("feature-x", "main")
  end

  it "refuses nothing when the project binds nothing to Claims" do
    expect(refusal(LandingHoldsRegistry::Registry.new({}))).to be_nil
  end

  it "refuses nothing when the landing has no booted project" do
    expect(refusal(nil)).to be_nil
  end

  it "refuses an overlapping landing in the words it always had when Claims is bound" do
    expect(refusal(LandingClaimsRegistry.landing_claims_registry))
      .to eq("feature-x changes lib/a.rb, in the area of other (lib)")
  end

  it "binds exactly one adapter to the port in Hecks, the pipeline's LandingClaims" do
    bound = boot_hecks_in_memory.registry.adapters.values.select { |adapter| adapter.port == described_class::PORT }
    expect(bound.map(&:name)).to eq(["LandingClaims"])
  end

  it "keeps the started Work items and the overlap rule out of delivery's Ruby" do
    sources = Dir.glob(File.join(library, "**", "*.rb")).map { |path| File.read(path) }
    expect(sources.grep(%r{StartedWork|AreaOverlap|hecks/hecks/adapters/(started_work|area_overlap)})).to be_empty
  end
end
