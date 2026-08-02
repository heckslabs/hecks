
require "spec_helper"

# THE RUST-FACING COUNTERPART TO spec/syntax_conformance_spec.rb.
#
# That file holds Ruby's builders to the language's declared syntax, in both
# directions. Nothing held RUST's parser to the same declaration at the
# ARGUMENT-NAME level — only at the WORD level, and only for the block-keyword
# near-miss list its own last example checks. `role:` proved the gap was real:
# `absorb_reference_to` and `parse_command`'s own reference_to handling both
# read a `, role:` kwarg that named NOTHING `Syntax::Argument` declares —
# matching neither builder's actual signature on either side — until the
# parser-reconciliation pass found it by hand and deleted it. Nothing had been
# checking, so nothing had caught it.
#
# This reads every kwarg-name literal parser.rs/parse_blocks.rs hardcode
# (`"optional:"`, `parse_flag_kwarg(line, "optional:")`, `extract_kwarg_string
# (line, "version")` — embedded-colon and bare-word forms both) and holds them
# to `Syntax::Argument`'s declared `named` values, in BOTH directions : a kwarg
# Rust reads that the language does not declare is the `role:` failure mode
# again ; a kwarg the language declares that NOTHING in Rust reads is a real
# argument silently unhandled, the other half of the same gap.
#
# DELIBERATELY FLAT, not scoped per (keyword, context) the way
# spec/syntax_conformance_spec's own argument checks are. Rust's kwarg readers
# are not context-aware — `parse_flag_kwarg(line, "optional:")` reads the same
# way whether the line came from Aggregate.attribute, Command.attribute, or
# Command.reference_to — so a flat set is the granularity that actually
# matches what the code does, not a stricter shape imposed on top of it.
RSpec.describe "Rust's parser holds the language's argument names" do
  def self.meta = Hecksagain::Bluebook::MetaValidator.grammar_registry.bluebook("Bluebook")

  # A proposed argument has no reader YET and a retired one has no reader
  # ANY MORE — holding either to Rust's actual reads would make the
  # lifecycle unusable, the same reason spec/syntax_conformance_spec's
  # LIVE_ARGUMENTS excludes them. An absent status reads as admitted (the
  # grown-column convention).
  def self.live?(row) = %w[admitted deprecated].include?(row[:status].to_s.empty? ? "admitted" : row[:status].to_s)

  def self.declared_named_arguments
    syntax = meta.aggregates.find { |a| a.hecks_name == "Syntax" }
    argument = syntax.value_objects.find { |vo| vo.hecks_name == "Argument" }
    argument.members
            .map(&:to_h)
            .select { |row| live?(row) }
            .map { |row| row[:named].to_s }
            .reject(&:empty?)
            .uniq
            .sort
  end

  DECLARED = declared_named_arguments

  RUST_FILES = %w[parser.rs parse_blocks.rs].freeze

  # EVERY KWARG NAME RUST'S PARSER ACTUALLY READS, in either spelling it uses :
  # a literal with the colon baked in (`"optional:"`), or a helper call naming
  # the bare word and adding the colon itself (`extract_kwarg_string(line,
  # "version")`). Read as TEXT, not executed — the same technique
  # spec/syntax_conformance_spec's near-miss example already uses to hold a
  # Rust source file to the declaration.
  def self.rust_referenced_kwargs
    sources = RUST_FILES.map { |name| File.read(File.join(InMemoryDomain::ROOT, "rust/src/bluebook/#{name}")) }

    embedded = sources.flat_map { |src| src.scan(/"([a-z_]+):"/).flatten }
    helper_calls = sources.flat_map do |src|
      src.scan(/(?:extract_kwarg_string|extract_after|parse_flag_kwarg|parse_quoted_kwarg)\(\s*\w+,\s*"([a-z_]+):?"/)
         .flatten
    end

    (embedded + helper_calls).uniq.sort
  end

  RUST_REFERENCED = rust_referenced_kwargs

  # THE ONE KIND DISTINCTION RUST'S READER ACTUALLY MAKES. Every other kwarg
  # is read as generic text (`extract_kwarg_string`/`extract_after`/
  # `parse_quoted_kwarg` — a quoted string or a bare token, kind-blind by
  # construction, matching the file's own "flat" reasoning above). `flag` is
  # the one kind with its own reader shape (`true`/`false`, never a string),
  # so it is the one place "declares kind X" and "reads argument shape X"
  # can actually be held to each other today — the model M3b's later kinds
  # extend, one reader shape at a time.
  def self.declared_kind(kind)
    syntax   = meta.aggregates.find { |a| a.hecks_name == "Syntax" }
    argument = syntax.value_objects.find { |vo| vo.hecks_name == "Argument" }
    argument.members
            .map(&:to_h)
            .select { |row| live?(row) && row[:kind].to_s == kind }
            .map { |row| row[:named].to_s }
            .reject(&:empty?)
            .uniq
            .sort
  end

  # `from:` IS DECLARED TWICE, ON PURPOSE. `transition`'s `from:` is
  # legitimately both kind "text" (one prior state) and kind "list"
  # (several) — the one named argument in the corpus where "kind" depends
  # on how many values are given, not on which argument it is. Excluded
  # from bin/ir_syntax_text's table for the same reason RESERVED_KEY exists
  # in spec/syntax_conformance_spec: a name this ambiguous cannot be held to
  # a single kind's assertion.
  DUAL_KIND_NAMES = %w[from].freeze

  def self.rust_asserted_reads(assert_fn)
    sources = RUST_FILES.map { |name| File.read(File.join(InMemoryDomain::ROOT, "rust/src/bluebook/#{name}")) }

    # `parse_flag_kwarg(line, "optional:")` takes the line and the kwarg ;
    # `assert_text_kwarg("admits:")`/`assert_number_kwarg("max_age:")` take
    # only the kwarg — one regex covers both call shapes.
    sources.flat_map { |src| src.scan(/#{assert_fn}\(\s*(?:\w+,\s*)?"([a-z_]+):?"\s*\)/).flatten }.uniq.sort
  end

  # Both directions, for every kind Rust's reader can actually be held to —
  # `flag` (its own reader, `parse_flag_kwarg`) and `text`/`number` (shared
  # extractors, so an explicit `assert_*_kwarg` call in front of the read is
  # what stands in for a dedicated reader — see assert_text_kwarg's own
  # comment in parse_blocks.rs).
  KIND_ASSERTIONS = {
    "flag"   => "parse_flag_kwarg",
    "text"   => "assert_text_kwarg",
    "number" => "assert_number_kwarg"
  }.freeze

  KIND_ASSERTIONS.each do |kind, assert_fn|
    it "reads every #{kind}-kind argument through #{assert_fn}, and nothing else through it" do
      declared = self.class.declared_kind(kind) - DUAL_KIND_NAMES
      read     = self.class.rust_asserted_reads(assert_fn)

      expect(read - declared).to be_empty,
                                 "#{assert_fn} reads #{(read - declared).inspect}, which Syntax::Argument " \
                                 "does not declare as kind #{kind.inspect} — the reader and the declaration " \
                                 "disagree about what shape this argument is"

      expect(declared - read).to be_empty,
                                 "the language declares #{(declared - read).inspect} as kind #{kind.inspect}, " \
                                 "and nothing in parser.rs or parse_blocks.rs reads it through #{assert_fn} — " \
                                 "either it is read without the kind check, or not read at all"
    end
  end

  it "reads at least one kwarg name from each source file, so a moved function doesn't silently empty this" do
    expect(RUST_REFERENCED).not_to be_empty
  end

  it "declares at least one named argument, so a language regression doesn't silently empty this" do
    expect(DECLARED).not_to be_empty
  end

  it "hardcodes no kwarg name the language does not declare" do
    ghosts = RUST_REFERENCED - DECLARED

    expect(ghosts).to be_empty,
                      "Rust's parser reads #{ghosts.inspect}, which Syntax::Argument does not " \
                      "declare as a named argument anywhere — the same failure shape as the " \
                      "deleted `role:` kwarg, a hand-typed name matching nothing real"
  end

  it "declares no named argument Rust's parser never reads" do
    unread = DECLARED - RUST_REFERENCED

    expect(unread).to be_empty,
                      "the language declares #{unread.inspect} as named arguments, and nothing " \
                      "in parser.rs or parse_blocks.rs reads any of them — a real argument, " \
                      "silently unhandled"
  end
end
