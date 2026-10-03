require "spec_helper"
require_relative "support/doctest_names"

# A doc that records a moment or a plan says so where a reader lands, so it cannot be
# read as the current state of the project (ADR 0070). The docs that skip the doctest
# gates (`DoctestNames::UNGATED_STATUS_DOCS`) and the files in `docs/archive/` each
# carry a status or historical-snapshot banner in their first lines.
module DocBanners
  ROOT_DIR = File.expand_path("..", __dir__)

  # How many lines from the top count as "the first lines".
  WINDOW = 12

  # A banner line opens with a bolded `Status` or `Historical snapshot`, optionally
  # inside a blockquote.
  MARKER = /\A(?:>\s*)?\*\*(?:Status|Historical snapshot)\b/

  # Listed docs that are living reference, not a record of a moment or a plan: they are
  # kept current in place, so a snapshot banner would be false.
  LIVING_REFERENCE = %w[
    architecture-map.md
    benchmarks.md
    COMMENT_STYLE_GUIDE.md
    COMMENT_STYLE_GUIDE_RUST.md
    migrating-2-to-3.md
    rubocop-custom-cops.md
    site-routes.md
    tools.md
  ].freeze

  # @param path [String] a markdown file
  # @return [Boolean] whether a banner line sits in the file's first lines
  def self.banner?(path)
    File.foreach(path).first(WINDOW).any? { |line| line.match?(MARKER) }
  end

  # @return [Array<String>] the listed docs that must carry a banner
  def self.required
    DoctestNames::UNGATED_STATUS_DOCS - LIVING_REFERENCE
  end

  # @return [Array<String>] the archived files that must carry a banner
  def self.archived
    Dir.glob(File.join(ROOT_DIR, "docs/archive/*.md")).reject { |path| File.basename(path) == "README.md" }
  end

  # @param what [String] the doc that lacks a banner
  # @return [String] the failure message
  def self.missing(what)
    "#{what} has no `**Status` or `**Historical snapshot` line in its first #{WINDOW} lines"
  end
end

RSpec.describe "dated-snapshot banners" do
  it "keeps the living-reference list inside the ungated list" do
    expect(DocBanners::LIVING_REFERENCE - DoctestNames::UNGATED_STATUS_DOCS).to be_empty
  end

  DocBanners.required.each do |doc|
    it "docs/#{doc} opens with a status or dated-snapshot banner" do
      path = File.join(DocBanners::ROOT_DIR, "docs", doc)

      expect(DocBanners.banner?(path)).to be(true), DocBanners.missing("docs/#{doc}")
    end
  end

  DocBanners.archived.each do |path|
    it "docs/archive/#{File.basename(path)} opens with a status or dated-snapshot banner" do
      expect(DocBanners.banner?(path)).to be(true), DocBanners.missing(path)
    end
  end
end
