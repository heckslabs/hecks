
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

  def self.declared_named_arguments
    syntax = meta.aggregates.find { |a| a.hecks_name == "Syntax" }
    argument = syntax.value_objects.find { |vo| vo.hecks_name == "Argument" }
    argument.members
            .map(&:to_h)
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
