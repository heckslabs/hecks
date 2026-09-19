require "spec_helper"

# **Every cargo feature and every generated Rust module lands in a check** —
# the Rust-facing half of spec/corpus_accounting_spec.rb. A partition, not
# a filter: each one is an in-repo Rust domain (fuzzed, regenerated,
# coverage- and parity-checked), a framework chapter, or sent by
# `Hecks::Corpus::RUST_ELSEWHERE` to a check that has to exist.
RSpec.describe "Hecks::Corpus, Rust-facing" do
  let(:corpus) { Hecks::Corpus }
  let(:root) { Hecks::Corpus::ROOT }
  let(:features) { corpus.rust_domains.map(&:feature) }

  it "sends every Cargo feature to exactly one bucket" do
    elsewhere = corpus::RUST_ELSEWHERE.keys
    expect(features & elsewhere).to be_empty
    expect(corpus.cargo_features.sort).to eq((features + elsewhere).sort)
  end

  it "gives each feature one in-repo domain directory" do
    expect(features.tally.select { |_, count| count > 1 }.keys).to be_empty
  end

  it "sends every generated module to exactly one bucket" do
    buckets = features + corpus.rust_framework_chapters + corpus::RUST_ELSEWHERE.keys
    expect(buckets.tally.select { |_, count| count > 1 }.keys).to be_empty
    expect(corpus.generated_modules.sort).to eq(buckets.sort)
  end

  it "has generated every in-repo Rust domain, from the directory it names" do
    corpus.rust_domains.each do |domain|
      expect(corpus.generated_source(domain.feature)).to eq(domain.dir.delete_prefix("#{root}/")), domain.feature
    end
    expect(corpus.rust_regen_order).to eq(corpus.rust_domains)
  end

  # bin/project_rust rewrites Cargo's `default` to whichever domain it ran
  # last, so the drift check's last domain must already be the committed
  # default — or every regen run would diff rust/Cargo.toml.
  it "regenerates the committed Cargo default last" do
    expect(corpus.rust_regen_order.last.feature).to eq(corpus.cargo_default)
  end

  it "attaches every framework chapter through some Rust domain's hecksagon" do
    hecksagons = corpus.rust_domains.flat_map { |domain| Dir.glob(File.join(domain.dir, "**", "*.hecksagon")) }
                       .map { |path| File.read(path) }.join("\n")
    corpus.rust_framework_chapters.each do |stem|
      chapter = corpus.chapter_name_of(File.join(root, "lib/hecks/framework/bluebook/#{stem}.bluebook"))
      expect(hecksagons).to match(/^\s*uses_framework\s+"#{chapter}"/), stem
    end
  end

  it "routes every elsewhere feature to a check that exists" do
    domain_dirs = corpus.members.map { |member| File.basename(corpus.domain_dir_of(member)).downcase }

    corpus::RUST_ELSEWHERE.each do |feature, route|
      expect(route.why).to match(/\S/)
      case route.check
      when :named_in
        expect(File.read(File.join(root, route.destination))).to include(route.names), feature
      when :external
        expect(domain_dirs).not_to include(feature), "#{feature} has an in-repo source now — it is a rust domain"
        expect(corpus.generated_source(feature)).to start_with("/"), "#{feature}'s module was generated in-repo"
      else
        raise "unknown RUST_ELSEWHERE check #{route.check.inspect}"
      end
    end
  end

  it "pends rust coverage only for modules that exist" do
    expect(corpus::RUST_COVERAGE_PENDING.keys - corpus.generated_modules).to be_empty
    expect(corpus::RUST_COVERAGE_PENDING.values).to all(match(/\S/))
  end
end
