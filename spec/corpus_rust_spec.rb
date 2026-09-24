require "spec_helper"

# Every cargo feature and every generated Rust module lands in a check —
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
    side_chapter_modules = (corpus.rust_framework_chapters + corpus.rust_vendored_chapters)
                           .map { |stem| corpus.rust_side_module_name(stem) }
    buckets = features + side_chapter_modules + corpus.rust_external_vendored_chapters + corpus::RUST_ELSEWHERE.keys
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

  # Some framework chapters (Privacy, first attached tonight — see
  # RUST_ELSEWHERE's own "lifeadelics" comment) are only ever attached
  # through an `:external` RUST_ELSEWHERE domain's own hecksagon, on a
  # real checkout `rust_attachment_hecksagon_text` reads directly off
  # this machine's filesystem — never present on a real CI runner
  # (confirmed: this exact example is `rspec_shard`'s own "skipping" on
  # every run tonight, including main's own last merge_group run,
  # 3ac17cdb — never once actually executed, not merely never caught
  # failing). Skipping, not asserting, whenever an `:external`
  # destination this repo declares isn't actually checked out here is
  # the honest answer to "can this machine prove that": full strength
  # on a real developer machine with every external product cloned
  # alongside this one (this one, right now), a clear pending marker
  # instead of a false pass or a false fail everywhere else.
  def self.every_external_destination_checked_out?
    Hecks::Corpus::RUST_ELSEWHERE.values.select { |route| route.check == :external }
                                 .all? { |route| Dir.exist?(File.expand_path(route.destination)) }
  end

  it "attaches every framework chapter through some Rust domain's hecksagon" do
    unless self.class.every_external_destination_checked_out?
      skip "an :external RUST_ELSEWHERE destination isn't checked out on this machine"
    end
    hecksagons = corpus.rust_attachment_hecksagon_text
    corpus.rust_framework_chapters.each do |stem|
      chapter = corpus.chapter_name_of(File.join(root, "lib/hecks/framework/bluebook/#{stem}.bluebook"))
      expect(hecksagons).to match(/^\s*uses_framework\s+"#{chapter}"/), stem
    end
  end

  # SAME PROOF, `uses_embryonaut_bluebook`'s own side — a vendored
  # package's chapter name isn't the file's own stem (the framework
  # check's assumption above), so it's read off the vendored member's own
  # bluebook header instead of a fixed `lib/hecks/framework/bluebook/`
  # path.
  it "attaches every vendored chapter through some Rust domain's hecksagon" do
    hecksagons = corpus.rust_attachment_hecksagon_text
    vendored_by_stem = corpus.members(:vendored).to_h { |member| [member.stem, member] }
    corpus.rust_vendored_chapters.each do |stem|
      member = vendored_by_stem.fetch(stem)
      chapter = corpus.chapter_name_of(corpus.bluebook_files(member.path))
      expect(hecksagons).to match(/^\s*uses_embryonaut_bluebook\s+"#{stem}"/), stem
      expect(chapter).to eq(Hecks::Naming.pascal(stem)), "#{member.path}: chapter #{chapter.inspect} != #{Hecks::Naming.pascal(stem).inspect}"
    end
  end

  # Same proof, an external RUST_ELSEWHERE domain's own vendored chapter
  # — `members(:vendored)` never reaches these (that glob only walks
  # `examples/*/vendor/embryonaut_bluebooks/*`), so each one's own
  # directory is resolved from RUST_EXTERNAL_VENDORED_CHAPTERS instead.
  # By definition every stem here is external-only (see
  # RUST_EXTERNAL_VENDORED_CHAPTERS) — skip guard, same reasoning as the
  # framework-chapter test above, applies unconditionally to this whole
  # example rather than per-stem.
  it "attaches every external vendored chapter through its own domain's hecksagon" do
    unless self.class.every_external_destination_checked_out?
      skip "an :external RUST_ELSEWHERE destination isn't checked out on this machine"
    end
    hecksagons = corpus.rust_attachment_hecksagon_text
    corpus.rust_external_vendored_chapters.each do |stem|
      dir = corpus.rust_external_vendored_domain_dir(stem)
      chapter = corpus.chapter_name_of(corpus.bluebook_files(dir))
      expect(hecksagons).to match(/^\s*uses_embryonaut_bluebook\s+"#{stem}"/), stem
      expect(chapter).to eq(Hecks::Naming.pascal(stem)), "#{dir}: chapter #{chapter.inspect} != #{Hecks::Naming.pascal(stem).inspect}"
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
