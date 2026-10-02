require_relative "doctest"

# Tracks which markdown doctest owns which chapter name: installed chapter
# names are never uninstalled, so collisions must be caught before boot.
module DoctestNames
  ROOT = InMemoryDomain::ROOT

  module_function

  # AUTHORING.md and index.md aren't guides with claims of their own to back.
  #
  # @return [Array<String>] every guide's own path, README.md included
  def guides
    (Dir.glob(File.join(ROOT, "docs/implemented/guides/*.md")) -
     [File.join(ROOT, "docs/implemented/guides/AUTHORING.md"),
      File.join(ROOT, "docs/implemented/guides/index.md")]) +
      [File.join(ROOT, "README.md")]
  end

  # Lists the DSL reference pages, one runnable example per word.
  #
  # @return [Array<String>] every DSL reference page's own path
  def reference
    Dir.glob(File.join(ROOT, "docs/implemented/reference/*.md")) -
      [File.join(ROOT, "docs/implemented/reference/index.md")]
  end

  # Lists every document this gate covers.
  #
  # @return [Array<String>] every gated document's own path: `guides` plus `reference`
  def all = guides + reference

  # Top-level docs/*.md files exempt from the doctest gate: status and
  # planning prose whose claims aren't fence-shaped, unlike a narrative guide.
  UNGATED_STATUS_DOCS = %w[
    1.0-readiness.md
    architecture-map.md
    benchmarks.md
    command-form-and-query-form-bluebook.md
    COMMENT_STYLE_GUIDE.md
    COMMENT_STYLE_GUIDE_RUST.md
    dsl-work-slices.md
    event-storming-policies.md
    future-features.md
    fuzzer-property-expansion-plan.md
    HECKS_IMPLEMENTATION_PLAN.md
    migrating-2-to-3.md
    query-dsl.md
    rails-integration.md
    rubocop-custom-cops.md
    running-a-rules-service.md
    rust-handwritten-refactor-slices.md
    tools.md
    value-object-identity-and-relationships-plan.md
  ].freeze

  # Nonempty means a new docs/*.md file landed with no decision yet: fold it
  # into `guides`, or add it to `UNGATED_STATUS_DOCS`.
  #
  # @return [Array<String>] basenames present at `docs/*.md` that `UNGATED_STATUS_DOCS`
  #   does not account for; empty when the list is still complete
  def unaccounted_top_level_docs
    Dir.glob(File.join(ROOT, "docs/*.md")).map { |path| File.basename(path) }.sort -
      UNGATED_STATUS_DOCS
  end

  # Chapter names each document invents, keyed by path. A document that loads
  # a corpus file instead of declaring `Hecks.bluebook` itself claims nothing.
  #
  # @return [Hash{String => Array<String>}] each gated document's own path, mapped to the
  #   chapter names it invents
  def claims
    all.to_h { |path| [path, Doctest.declared_domains(Doctest.parse(path))] }
  end

  # Finds every chapter name two documents both claim.
  #
  # @return [Array<String>] one sentence per colliding chapter name, empty when none collide
  def collisions
    owners = {}
    claims.flat_map do |path, domains|
      domains.filter_map do |domain|
        owner = owners[domain]
        owners[domain] = path unless owner
        next unless owner

        "#{relative(path)} declares #{domain.inspect}, already declared by #{relative(owner)} " \
          "— a chapter name is claimed once across the guides and the reference together"
      end
    end
  end

  # Shortens an absolute path for display.
  #
  # @param path [String] an absolute path under `ROOT`
  # @return [String] `path`, relative to `ROOT`
  def relative(path) = path.delete_prefix("#{ROOT}/")
end
