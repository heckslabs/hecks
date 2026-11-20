require "spec_helper"
require "tmpdir"
require "json"
require "hecks/hecks/adapters/codebase/test_suite"
require "hecks/hecks/adapters/codebase/test_suite/semantics_seeding"

# The modules beside `Codebase::TestSuite` that do its asks: each takes values and answers a value
# or refuses with `ConsoleCapture::Failure`.
RSpec.describe Hecks::Adapters::Codebase::TestSuite do
  let(:root) { InMemoryDomain::ROOT }
  let(:failure) { Hecks::Adapters::ConsoleCapture::Failure }

  describe described_class::PatternCases do
    it "records one row per pattern and input, and is what the committed cases hold" do
      committed = JSON.parse(File.read(File.join(root, "spec/corpus/fixtures/patterns.json")))

      expect(JSON.parse(described_class.json)).to eq(committed)
    end
  end

  describe described_class::SpecShards do
    def shard(group) = described_class.files(root: root, group: group, groups: 3)

    it "splits the spec files so every file lands in exactly one group", :aggregate_failures do
      groups = (1..3).map { |group| shard(group) }

      expect(groups.flatten.sort).to eq(Dir.glob("spec/**/*_spec.rb", base: root).sort)
      expect(groups.map(&:size).min).to be > 0
    end

    it "refuses a group outside the split" do
      expect { shard(4) }.to raise_error(failure, /group must be between 1 and 3, got 4/)
    end
  end

  describe described_class::IoParallelSpecs do
    around { |example| Dir.mktmpdir { |dir| (@dir = dir) && example.run } }

    def listing(exclude, tags, at = root) = described_class::Listing.new(root: at, exclude: exclude, tags: tags)

    it "refuses a listing with no tag filter" do
      expect { described_class.files(listing("^spec/qa", [])) }.to raise_error(failure, /needs an RSpec tag filter/)
    end

    it "refuses an exclude pattern that leaves no candidate files" do
      expect { described_class.files(listing(".", %w[--tag io])) }.to raise_error(failure, /ZERO candidate spec files/)
    end

    def check_stale_list
      File.write(File.join(@dir, "list.txt"), "spec/gone_spec.rb\n")
      described_class.check(listing("^x", %w[--tag io], @dir), "list.txt", ["spec/new_spec.rb"])
    end

    it "names what a stale committed list is missing and what it lists in vain" do
      expect { check_stale_list }
        .to raise_error(failure, %r{list.txt is out of date.(?=.*spec/new_spec.rb)(?=.*spec/gone_spec.rb)}m)
    end

    it "tells a stale list's reader the launcher command that rewrites it" do
      expect { check_stale_list }.to raise_error(failure, /test_suite_run.write_io_parallel_spec_list! exclude.value=\\\^x/)
    end
  end

  describe described_class::StressRun do
    def runs_that(pass)
      allow(described_class).to receive(:run_once) do |_root, _files, seed, label|
        { label: label, seed: seed, success: pass, output: "boom", reproduce: "x" }
      end
    end

    it "names what ran and ends clean when every run passes" do
      runs_that(true)

      expect(described_class.call(root: root, runs: 2, seed_start: 5, parallel: 1)).to include("CLEAN — 4/4 runs passed.")
    end

    it "refuses with each failing run's saved log" do
      runs_that(false)

      Dir.mktmpdir do |dir|
        expect { described_class.call(root: dir, runs: 1, seed_start: 3, parallel: 1) }
          .to raise_error(failure, %r{FOUND FLAKINESS — 2/2})
      end
    end
  end

  describe described_class::SemanticsSeeding do
    it "seeds nothing when every fixture already carries its expect" do
      expect(described_class.call(root: root)).to start_with("nothing to seed")
    end
  end
end
