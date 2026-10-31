require "spec_helper"
require "tmpdir"
require "fileutils"

# Who the launcher's help is for: someone working on a hecks checkout sees the maintainer's
# commands, anyone else sees what they run against their own project, plus the bluebooks.
RSpec.describe Hecks::Adapters::Driving::LauncherOptions do
  let(:root) { Dir.mktmpdir("launcher-audience") }

  after { FileUtils.rm_rf(root) }

  def checkout(at = root)
    FileUtils.mkdir_p(File.join(at, "lib"))
    File.write(File.join(at, "hecks.gemspec"), "")
  end

  describe ".maintainer?" do
    it "is true in a hecks checkout, and in any directory below one", :aggregate_failures do
      checkout
      deep = File.join(root, "lib", "hecks", "adapters", "driving")
      FileUtils.mkdir_p(deep)

      expect(described_class.maintainer?(root, {})).to be(true)
      expect(described_class.maintainer?(deep, {})).to be(true)
    end

    it "is false in a project that merely has a gemspec of its own name, or no lib beside it" do
      File.write(File.join(root, "shop.gemspec"), "")
      File.write(File.join(root, "hecks.gemspec"), "")

      expect(described_class.maintainer?(root, {})).to be(false)
    end

    it "is false anywhere else" do
      expect(described_class.maintainer?(root, {})).to be(false)
    end

    it "takes HECKS_MAINTAINER as the answer, either way", :aggregate_failures do
      checkout

      expect(described_class.maintainer?(root, "HECKS_MAINTAINER" => "0")).to be(false)
      expect(described_class.maintainer?(Dir.mktmpdir("elsewhere"), "HECKS_MAINTAINER" => "1")).to be(true)
    end
  end

  describe ".audience" do
    let(:setting) { { maintainer: %w[LanguageRun], bluebooks: %w[Deploy], maintainer_bluebooks: %w[Bluebook] } }

    it "hides the maintainer's aggregates from anyone else and points at the bluebooks" do
      expect(described_class.audience(setting, false)).to eq(hide: %w[LanguageRun], declarations: %w[Deploy], everyday: [])
    end

    it "hides nothing from a maintainer, and adds the language's own bluebooks" do
      expect(described_class.audience(setting, true)).to eq(hide: [], declarations: %w[Deploy Bluebook], everyday: [])
    end

    it "passes the everyday names on, to every audience", :aggregate_failures do
      daily = setting.merge(everyday: %i[operation.run checkout.status])

      expect(described_class.audience(daily, false)).to include(everyday: %w[operation.run checkout.status])
      expect(described_class.audience(daily, true)).to include(everyday: %w[operation.run checkout.status])
    end

    it "leaves a bluebook that did not opt in whole" do
      expect(described_class.audience(nil, false)).to eq({})
    end
  end

  describe "the Hecks bluebook's own setting" do
    # The aggregates only a maintainer of a hecks checkout runs: the language, its checks and
    # projections, the test suite, and the publishing of a release.
    let(:codebase) do
      %w[LanguageRun KernelRun ConformanceRun RegenerationRun GateRun StyleRun ScriptRun InspectionRun CodemodRun
         TestSuiteRun CorpusRun PublishingRun PromotionRun]
    end
    let(:hidden) do
      world = File.read(File.expand_path("../../lib/hecks/hecks/hecks.world", __dir__))
      world[/maintainer: %w\[(.*?)\]/m, 1].split
    end

    it "hides exactly the Codebase aggregates and the release ones, nothing a project runs", :aggregate_failures do
      expect(hidden).to include(*codebase)
      expect(hidden - codebase).to contain_exactly("Release", "SyntaxBootCache")
    end
  end
end
