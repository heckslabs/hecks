# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "hecks/hecks/adapters/record_index"

# Index.Find searches the work items, findings and decisions by their words, with no model.
RSpec.describe Hecks::Adapters::RecordIndex do
  def registry_of(**stores)
    aggregates = stores.keys.map { |name| double(hecks_name: name.to_s) }
    double(bluebook: double(aggregates: aggregates)).tap do |registry|
      allow(registry).to receive(:repository) { |_, aggregate| double(all: stores.fetch(aggregate.hecks_name.to_sym)) }
    end
  end

  def rec(**fields) = fields

  def work(key, title, detail = "") = rec(work: key, title: title, detail: detail)

  def index(works = [], findings: [], adrs: [])
    registry = registry_of(Work: works, Finding: findings, Adr: adrs)
    described_class.new(registry: registry, settings: { path: ":memory:" })
  end

  def rows(index, words, **held) = index.find(words: words, **held)[:text].lines.map(&:chomp)

  let(:skip) { work("zsh-skip-backstop", "A spec skips without zsh", "the skip backstop fails") }
  let(:train) { rec(finding: "train-9", title: "Train failed", body: "the zsh skip named by the backstop") }

  it "names every record that holds the words, with its kind and id" do
    hits = rows(index([skip, work("other", "Unrelated")], findings: [train]), "zsh skip")
    expect(hits.map { |row| row.split(":").first }).to contain_exactly("work zsh-skip-backstop", "finding train-9")
  end

  it "answers three items of one failing line with one hit set naming all three" do
    items = %w[a b c].map { |key| work("run-#{key}", "A Codebase run failed", "check line: quick gate") }
    expect(rows(index(items), "Codebase run failed").size).to eq(3)
  end

  it "returns nothing for words in no record" do
    expect(rows(index([skip]), "quokka")).to be_empty
  end

  it "narrows to one kind" do
    expect(rows(index([skip], findings: [train]), "zsh", kind: "finding").size).to eq(1)
  end

  it "answers a search of 500 items in under 50 ms once indexed", :aggregate_failures do
    held = index((1..500).map { |n| work("w#{n}", "item #{n} title", "detail about thing#{n}") })
    rows(held, "item")
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    expect(rows(held, "thing250")).to match([/\Awork w250: .*thing250\z/])
    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 0.05
  end

  it "takes up a changed record on the next query" do
    changed = [work("w1", "old words")]
    held = index(changed)
    rows(held, "old")
    changed[0] = work("w1", "fresh words")
    expect(rows(held, "old")).to be_empty
  end

  it "loads without sqlite3, which only a Store needs" do
    code = "$LOAD_PATH.unshift('lib'); require 'hecks/hecks/adapters/record_index'; exit(defined?(SQLite3) ? 1 : 0)"
    expect(system(RbConfig.ruby, "-e", code, out: File::NULL, err: File::NULL)).to be(true)
  end
end
