require "spec_helper"

# A version, a commit count or a `VERSION =` string in a doc is true on the day it is
# written and wrong after the next release or merge (ADR 0070). Docs say "the current
# release" and leave the number to `lib/hecks/version.rb` and the tags. Dated records
# under `docs/audits`, `docs/decisions`, `docs/wayfinder` and `docs/archive` are
# snapshots by design and are not scanned.
module DocsStaleVersion
  ROOT_DIR = File.expand_path("..", __dir__)

  CLAIMS = [
    /VERSION =/,
    /\d+ commits/,
    /currently \d+\.\d+\.\d+/,
    /hecks \d+\.\d+\.\d+/
  ].freeze

  EXCLUDED = %w[audits decisions wayfinder archive].map { |dir| File.join(ROOT_DIR, "docs", dir, "") }.freeze

  # Docs under `docs/` whose banner marks them as a snapshot of one day, so a count in
  # them is a record of that day. Adding a path here says the doc really is a snapshot.
  SNAPSHOT_ALLOW_LIST = %w[
    docs/implemented/postgres-era-adapter-split-plan.md
    docs/implemented/rust-experiment.md
  ].freeze

  # @return [Array<String>] every scanned markdown path under `docs/`
  def self.scanned
    Dir.glob(File.join(ROOT_DIR, "docs/**/*.md")).reject { |path| EXCLUDED.any? { |dir| path.start_with?(dir) } }
  end

  # @return [Array<String>] one `path:line: text` entry per claim outside the allow-list
  def self.hits
    scanned.flat_map do |path|
      relative = path.delete_prefix("#{ROOT_DIR}/")
      next [] if SNAPSHOT_ALLOW_LIST.include?(relative)

      File.readlines(path).each_with_index.filter_map do |line, index|
        "#{relative}:#{index + 1}: #{line.strip}" if CLAIMS.any? { |pattern| line.match?(pattern) }
      end
    end
  end

  # @param relative [String] an allow-listed path
  # @return [Boolean] whether the doc opens with a bolded banner line
  def self.banner?(relative)
    File.foreach(File.join(ROOT_DIR, relative)).first(12).any? { |line| line.match?(/\A(?:>\s*)?\*\*[A-Z]/) }
  end
end

RSpec.describe "docs carry no stale version or commit count" do
  it "scans the docs it means to" do
    getting_started = File.join(DocsStaleVersion::ROOT_DIR, "docs/implemented/guides/getting-started.md")

    expect(DocsStaleVersion.scanned).to include(getting_started)
    expect(DocsStaleVersion.scanned.grep(%r{/docs/(?:audits|decisions|wayfinder|archive)/})).to be_empty
  end

  it "flags every claim outside the snapshot allow-list" do
    hits = DocsStaleVersion.hits

    expect(hits).to be_empty,
                    "a version or commit count goes stale — drop the number, or banner the doc " \
                    "as a snapshot and list it in the allow-list:\n#{hits.join("\n")}"
  end

  DocsStaleVersion::SNAPSHOT_ALLOW_LIST.each do |relative|
    it "#{relative} is banner-marked as a snapshot" do
      expect(DocsStaleVersion.banner?(relative)).to be(true), "#{relative} is on the allow-list but has no banner"
    end
  end
end
