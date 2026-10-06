require "spec_helper"

# Every cargo feature and generated Rust module lands in a check: the Rust-facing half of
# spec/corpus_accounting_spec.rb.
RSpec.describe "Hecks::Corpus, Rust-facing" do
  let(:corpus) { Hecks::Corpus }
  let(:root) { Hecks::Corpus::ROOT }
  let(:features) { corpus.rust_domains.map(&:feature) }

  it "sends every Cargo feature to exactly one bucket", :aggregate_failures do
    elsewhere = corpus::RUST_ELSEWHERE.keys
    expect(features & elsewhere).to be_empty
    expect(corpus.cargo_features.sort).to eq((features + elsewhere).sort)
  end

  it "gives each feature one in-repo domain directory" do
    expect(features.tally.select { |_, count| count > 1 }.keys).to be_empty
  end

  it "sends every generated module to exactly one bucket", :aggregate_failures do
    side_chapter_modules = (corpus.rust_framework_chapters + corpus.rust_vendored_chapters)
                           .map { |stem| corpus.rust_side_module_name(stem) }
    buckets = features + side_chapter_modules + corpus.rust_sibling_chapters + corpus::RUST_ELSEWHERE.keys
    expect(buckets.tally.select { |_, count| count > 1 }.keys).to be_empty
    expect(corpus.generated_modules.sort).to eq(buckets.sort)
  end

  it "finds payments as a sibling chapter beside an in-repo domain's own bluebook" do
    expect(corpus.rust_sibling_chapters).to include("payments")
  end

  it "has generated every in-repo Rust domain, from the directory it names", :aggregate_failures do
    corpus.rust_domains.each do |domain|
      expect(corpus.generated_source(domain.feature)).to eq(domain.dir.delete_prefix("#{root}/")), domain.feature
    end
    expect(corpus.rust_regen_order).to eq(corpus.rust_domains)
  end

  # hecks project_rust rewrites Cargo's `default` to whichever domain it ran
  # last, so the drift check's last domain must already be the committed
  # default — or every regen run would diff rust/Cargo.toml.
  it "regenerates the committed Cargo default last" do
    expect(corpus.rust_regen_order.last.feature).to eq(corpus.cargo_default)
  end

  it "attaches every framework chapter through some Rust domain's hecksagon" do
    hecksagons = corpus.rust_attachment_hecksagon_text
    corpus.rust_framework_chapters.each do |stem|
      chapter = corpus.chapter_name_of(File.join(root, "lib/hecks/framework/bluebook/#{stem}.bluebook"))
      expect(hecksagons).to match(/^\s*attaches\s+"#{chapter}"/), stem
    end
  end

  it "attaches every vendored chapter through some Rust domain's hecksagon" do
    hecksagons = corpus.rust_attachment_hecksagon_text
    corpus.rust_vendored_chapters.each do |stem|
      expect(hecksagons).to match(/^\s*attaches\s+"#{stem}",\s*from:\s*:vendor/), stem
    end
  end

  # A vendored chapter's name is not its file stem, so it is read from the bluebook header.
  def vendored_chapter(stem)
    member = corpus.members(:vendored).to_h { |candidate| [candidate.stem, candidate] }.fetch(stem)
    [member.path, corpus.chapter_name_of(corpus.bluebook_files(member.path))]
  end

  it "names every vendored chapter by the stem of its file" do
    corpus.rust_vendored_chapters.each do |stem|
      path, chapter = vendored_chapter(stem)
      expected = Hecks::Naming.pascal(stem)
      expect(chapter).to eq(expected), "#{path}: chapter #{chapter.inspect} != #{expected.inspect}"
    end
  end

  def expect_route_checked(feature, route)
    raise "unknown RUST_ELSEWHERE check #{route.check.inspect}" unless route.check == :named_in

    expect(File.read(File.join(root, route.destination))).to include(route.names), feature
  end

  it "routes every elsewhere feature to a check that exists", :aggregate_failures do
    corpus::RUST_ELSEWHERE.each do |feature, route|
      expect(route.why).to match(/\S/)
      expect_route_checked(feature, route)
    end
  end

  it "pends rust coverage only for modules that exist", :aggregate_failures do
    expect(corpus::RUST_COVERAGE_PENDING.keys - corpus.generated_modules).to be_empty
    expect(corpus::RUST_COVERAGE_PENDING.values).to all(match(/\S/))
  end
end
