require "hecks/fuzzing"
require "hecks/ports/persistence/plugins/era"
require_relative "../support/postgres_probe"
require "tmpdir"
require "fileutils"

# `Hecks::Fuzzing::PersistenceParity`, PROVEN AGAINST THE REAL THING — not
# a stand-in for it. Every property this file exists to prove (agreement
# on an ordinary step list, a real divergence actually surfacing) is a
# fact about a REAL `PG.connect` against a REAL, disposable Postgres
# database — mocking `IsolatedBoot`'s own `:postgres_era` adapter, or
# `PersistenceParity.diff` itself, would prove nothing about whether the
# mechanism this mode actually ships can reach real PostgresEra SQL at
# all, which is the entire reason this mode exists (see `PersistenceParity`'s
# own header).
#
# A THROWAWAY FIXTURE DOMAIN, NEVER `examples/` — same discipline
# `spec/qa_sweep_all_spec.rb`'s own `FIXTURE_TARGET_BLUEBOOK` already
# holds itself to (that file's own comment explains why: a "clean"
# example must never depend on some OTHER, actively-changing part of this
# corpus staying any particular shape). `examples/directory` gets its own
# real, end-to-end coverage in `spec/qa_sweep_persistence_parity_spec.rb`
# instead — this file only needs to prove the MECHANISM, not re-prove
# `directory` is clean every time this spec runs.
#
# A DISPOSABLE DATABASE OWNED HERE, EXACTLY `spec/qa_sweep_all_spec.rb`'s
# OWN PATTERN — created in `before(:all)`, dropped in `after(:all)`, a
# name that could never collide with the real `hecks_quality_control`
# ledger or any real deployment's own database.
RSpec.describe Hecks::Fuzzing::PersistenceParity, :io do
  PERSISTENCE_PARITY_SPEC_DATABASE = "hecks_persistence_parity_spec".freeze

  # ONE AGGREGATE, ONE COMMAND, ONE OPTIONAL STRING ATTRIBUTE — nothing
  # here needs a `compute`/`rekey` translation edge (this spec is about
  # `PersistenceParity.diff` itself, not about `examples/directory`'s own
  # edge — see this file's own header). `PostgresEra`-bound, same as
  # `examples/directory`, so `IsolatedBoot#rebind_to_postgres_era!`'s own
  # rewrite has a real binding to rewrite FROM as well as TO.
  #
  # NAMED `PERSISTENCE_PARITY_FIXTURE_BLUEBOOK`, DELIBERATELY NOT THE
  # GENERIC `FIXTURE_BLUEBOOK`/`FIXTURE_HECKSAGON` OTHER SPEC FILES USE —
  # a real Ruby gotcha, found live: `CONST = value` written directly
  # inside an `RSpec.describe do ... end` block assigns at the block's
  # own LEXICAL scope (top-level, i.e. `Object`), never inside the
  # dynamically-created example-group class, because `describe` takes an
  # ordinary BLOCK, not a `class`/`module` keyword body. Two spec files
  # that both write `FIXTURE_HECKSAGON = ...` this way are defining the
  # SAME top-level constant — whichever one Ruby loads LAST silently
  # overwrites the other's, so the FIRST file's own `before(:all)`
  # (which runs later, at RUN time, reading the constant fresh) can end
  # up writing a COMPLETELY DIFFERENT spec's own fixture text to disk.
  # `spec/qa_sweep_persistence_parity_spec.rb`'s own `FIXTURE_HECKSAGON`
  # collided with this file's exactly this way before both were renamed —
  # confirmed live by the `Hecks::Bluebook::DSL::Malformed` it produced.
  PERSISTENCE_PARITY_FIXTURE_BLUEBOOK = <<~RUBY.freeze
    Hecks.bluebook "PersistenceParityFixture" do
      vision "A trivially well-behaved fixture, authored only to prove Hecks::Fuzzing::PersistenceParity itself works — never examples/, so this spec never depends on this repository's own live corpus staying any particular shape."
      supporting

      aggregate "Widget" do
        description "One numbered widget and an optional note."

        identified_by :reference

        attribute :reference, WidgetReference
        attribute :note,      WidgetNote

        value_object("WidgetReference") { attribute :value, String }
        value_object("WidgetNote") { attribute :value, String, optional: true }

        command "Open" do
          goal "Open a widget under its own reference, with an optional note"

          attribute :reference, WidgetReference
          attribute :note,      WidgetNote

          sets :reference
          sets :note

          emits "WidgetOpened"
        end
      end
    end
  RUBY

  PERSISTENCE_PARITY_FIXTURE_HECKSAGON = <<~RUBY.freeze
    Hecks.hecksagon "PersistenceParityFixture" do
      PersistenceParityFixture::Widget.persisted_by("PostgresEra")
    end
  RUBY

  before(:all) do
    skip "no reachable Postgres — start one to run this spec" unless PostgresProbe.available?

    @fixture_root = Dir.mktmpdir("persistence_parity_spec")
    File.write(File.join(@fixture_root, "fixture.bluebook"), PERSISTENCE_PARITY_FIXTURE_BLUEBOOK)
    File.write(File.join(@fixture_root, "fixture.hecksagon"), PERSISTENCE_PARITY_FIXTURE_HECKSAGON)

    admin = PG.connect(dbname: "postgres")
    admin.exec("DROP DATABASE IF EXISTS #{PERSISTENCE_PARITY_SPEC_DATABASE} WITH (FORCE)")
    admin.exec("CREATE DATABASE #{PERSISTENCE_PARITY_SPEC_DATABASE}")
    admin.close
  end

  after(:all) do
    next unless PostgresProbe.available?

    admin = PG.connect(dbname: "postgres")
    admin.exec("DROP DATABASE IF EXISTS #{PERSISTENCE_PARITY_SPEC_DATABASE} WITH (FORCE)")
    admin.close
    FileUtils.remove_entry(@fixture_root)
  end

  # ONE SCHEMA PER EXAMPLE, NEVER SHARED — the same isolation
  # `IsolatedBoot#ensure_postgres_era_schema!` gives every ephemeral boot
  # inside a single sweep, applied here at the EXAMPLE level so two
  # examples in this file can never see each other's own widgets.
  def diff(steps, schema:)
    described_class.diff(@fixture_root, steps, database: PERSISTENCE_PARITY_SPEC_DATABASE, schema: schema)
  end

  def open_step(reference, note = nil)
    args = { "reference" => { "value" => reference } }
    args["note"] = note.nil? ? {} : { "value" => note }
    { "verb" => "PersistenceParityFixture::Widget.Open", "args" => args }
  end

  it "agrees on an ordinary, well-behaved step list — instances, events and refusals alike" do
    steps = [
      open_step("w1", "hello"),
      open_step("w2"),
      # A refusal both sides should reach identically — `identified_by`
      # uniqueness, the same guard on both engines since neither side's
      # ADAPTER is involved in enforcing it.
      open_step("w1", "duplicate")
    ]

    expect(diff(steps, schema: "agree_run")).to eq([])
  end

  # THE SYNTHETIC BREAK — proves this mode can actually FIRE, the same
  # discipline `spec/qa_sweep_all_spec.rb`'s own `found_one` example holds
  # itself to: a divergence this spec owns outright, forever, never one
  # that depends on some real bug elsewhere staying unfixed. A NUL byte
  # (Ruby's "\u0000" escape) is a completely ordinary Ruby String character — Memory
  # stores and returns it unremarked, confirmed live while building this
  # mode — but Postgres's own jsonb text encoding CANNOT represent one AT
  # ALL (`PG::UntranslatableCharacter: ... cannot be converted to text`),
  # a hard, permanent PostgreSQL limitation, not a hecks bug that could
  # ever get quietly fixed out from under this spec. Exactly the shape of
  # "quiet divergence" this whole practice exists to catch, just LOUD
  # instead of silent: a value Memory happily accepts, a real PostgresEra
  # deployment cannot actually honor.
  #
  # `PersistenceParity.diff` itself does not rescue this — same
  # architecture as `Hecks::Fuzzing::Properties.check` (`bin/qa_sweep`'s
  # own `ruby_only_outcome` is what wraps THAT in a `rescue StandardError`,
  # not the check itself); `bin/qa_sweep`'s own `persistence_parity_outcome`
  # is the equivalent wrapper for this mode, proven end to end in
  # `spec/qa_sweep_persistence_parity_spec.rb`.
  it "surfaces a real, permanent Memory-vs-PostgresEra divergence — a NUL byte no real jsonb column can store" do
    steps = [open_step("w1", "has\u0000nul")]

    expect { diff(steps, schema: "break_run") }.to raise_error(PG::UntranslatableCharacter)
  end
end
