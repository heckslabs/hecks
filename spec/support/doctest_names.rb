require_relative "doctest"

# Which markdown runs, and who owns which name.
#
# Two sets of executable documentation now share one process: the guides,
# which are narratives, and the DSL reference, which is one page per
# context and one runnable example per word. They are separate specs
# because they fail for different reasons and a reader chasing a red
# example should land in the right one — but they are one namespace.
#
# `Facade::Surface.install` (lib/hecks/facade/surface.rb) installs a
# chapter's name and every one of its aggregates' bare names onto Object,
# and nothing ever uninstalls them. Two files inventing the same chapter
# would therefore rebind whichever booted last, and under randomized spec
# order that is a coin flip rather than a failure. So the claim is
# checked across the union, once, before anything boots.
module DoctestNames
  ROOT = InMemoryDomain::ROOT

  module_function

  # AUTHORING.md is the contract for writing these, and index.md is a
  # generated table of contents — neither is a document with claims of
  # its own to back.
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

  # Everything at docs/*.md (one level, not docs/implemented/, not the
  # ADRs under docs/decisions/, not docs/audits/ or docs/prds/) is not a
  # guide, and this list is why: planning, status, and survey documents
  # (1.0-readiness.md, future-features.md, architecture-map.md, ...)
  # rather than the narrative Ruby tutorials `guides` runs. Forcing a
  # runnable fence into "what's the 1.0 blocker" or "what does the
  # architecture map show" would manufacture an example with nothing
  # real to assert, the same vacuous-pass shape `guides_spec.rb` already
  # refuses to let a zero-fence guide get away with — so these stay out
  # of the doctest gate on purpose, not by the accident of a glob that
  # simply never reached this far.
  #
  # That is a real gap, not a comfortable one: these are precisely the
  # documents that make claims about the project's own properties
  # (durability, isolation, coverage) rather than about the DSL's
  # runtime behavior, and prose claims about a system property are not
  # fence-shaped — no doctest proves "boot is fresh per test" or "no
  # console view exposes this password." The closest thing this project
  # has to a check on those claims is a periodic manual claim-audit (the
  # 2026-08-26 reconciliation pass is the one precedent), not doc_
  # coverage or guides_spec.
  #
  # This list exists so that gap stays a decision, checked below by
  # `unaccounted_top_level_docs`, rather than driftable-by-accident the
  # moment somebody adds a seventeenth file here without ever deciding
  # whether it belongs in `guides` instead.
  UNGATED_STATUS_DOCS = %w[
    1.0-readiness.md
    adoption-readiness.md
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
    hecks-survey-what-we-wish-we-had.md
    query-dsl.md
    rails-integration.md
    rubocop-custom-cops.md
    rust-handwritten-refactor-slices.md
    tools.md
    value-object-identity-and-relationships-plan.md
  ].freeze

  # Empty means the exclusion above is still the complete, deliberate
  # list — a nonempty result means a new docs/*.md file landed and
  # nobody decided yet whether it belongs in `guides` (write it as a
  # narrative with real fences) or on the list above (a status/planning
  # document, exempt with the same reasoning as its neighbors).
  # @return [Array<String>] basenames present at `docs/*.md` that `UNGATED_STATUS_DOCS`
  #   does not account for; empty when the list is still complete
  def unaccounted_top_level_docs
    Dir.glob(File.join(ROOT, "docs/*.md")).map { |path| File.basename(path) }.sort -
      UNGATED_STATUS_DOCS
  end

  # Every chapter name each document invents, keyed by path. A document
  # that instead `Kernel.load`s a real corpus file never writes that
  # chapter's own `Hecks.bluebook` line itself, so it claims nothing and
  # any number of documents may share one corpus example safely — see
  # `Doctest.declared_domains` for why that is deliberate. It is also the
  # reason the reference pages prefer loading the corpus: 105 invented
  # chapters would be 105 names to keep distinct, and the corpus is
  # already the honest thing to document a shipped language with.
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
