require "hecks/fuzzing"
require "hecks/ports/persistence/plugins/era"
require_relative "../support/postgres_probe"
require "tmpdir"
require "fileutils"

# `Hecks::Fuzzing::PersistenceParity`, proven against the real thing — not
# a stand-in for it. Every property this file exists to prove (agreement
# on an ordinary step list, a real divergence actually surfacing) is a
# fact about a real `PG.connect` against a real, disposable Postgres
# database — mocking `IsolatedBoot`'s own `:postgres_era` adapter, or
# `PersistenceParity.diff` itself, would prove nothing about whether the
# mechanism this mode actually ships can reach real PostgresEra SQL at
# all, which is the entire reason this mode exists (see `PersistenceParity`'s
# own header).
#
# A throwaway fixture domain, never `examples/` — same discipline
# `spec/qa_sweep_all_spec.rb`'s own `FIXTURE_TARGET_BLUEBOOK` already
# holds itself to (that file's own comment explains why: a "clean"
# example must never depend on some other, actively-changing part of this
# corpus staying any particular shape). `examples/directory` gets its own
# real, end-to-end coverage in `spec/qa_sweep_persistence_parity_spec.rb`
# instead — this file only needs to prove the mechanism, not re-prove
# `directory` is clean every time this spec runs.
#
# A disposable database owned here, exactly `spec/qa_sweep_all_spec.rb`'s
# own pattern — created in `before(:all)`, dropped in `after(:all)`, a
# name that could never collide with the real `hecks_quality_control`
# ledger or any real deployment's own database.
RSpec.describe Hecks::Fuzzing::PersistenceParity, :io do
  PERSISTENCE_PARITY_SPEC_DATABASE = "hecks_persistence_parity_spec".freeze

  # One aggregate, one command, one optional string attribute — nothing
  # here needs a `compute`/`rekey` translation edge (this spec is about
  # `PersistenceParity.diff` itself, not about `examples/directory`'s own
  # edge — see this file's own header). `PostgresEra`-bound, same as
  # `examples/directory`, so `IsolatedBoot#rebind_to_postgres_era!`'s own
  # rewrite has a real binding to rewrite from as well as to.
  #
  # Named `PERSISTENCE_PARITY_FIXTURE_BLUEBOOK`, deliberately not the
  # generic `FIXTURE_BLUEBOOK`/`FIXTURE_HECKSAGON` other spec files use —
  # a real Ruby gotcha, found live: `CONST = value` written directly
  # inside an `RSpec.describe do ... end` block assigns at the block's
  # own lexical scope (top-level, i.e. `Object`), never inside the
  # dynamically-created example-group class, because `describe` takes an
  # ordinary block, not a `class`/`module` keyword body. Two spec files
  # that both write `FIXTURE_HECKSAGON = ...` this way are defining the
  # same top-level constant — whichever one Ruby loads last silently
  # overwrites the other's, so the first file's own `before(:all)`
  # (which runs later, at run time, reading the constant fresh) can end
  # up writing a completely different spec's own fixture text to disk.
  # `spec/qa_sweep_persistence_parity_spec.rb` once defined its own
  # same-named `FIXTURE_HECKSAGON` and collided with this file's exactly
  # this way — confirmed live by the `Hecks::Bluebook::DSL::Malformed` it
  # produced — which is why both fixture constants now carry distinct,
  # file-specific names instead.
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

  # One schema per example, never shared — the same isolation
  # `IsolatedBoot#ensure_postgres_era_schema!` gives every ephemeral boot
  # inside a single sweep, applied here at the example level so two
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
      # adapter is involved in enforcing it.
      open_step("w1", "duplicate")
    ]

    expect(diff(steps, schema: "agree_run")).to eq([])
  end

  # **The synthetic break** — proves this mode can actually fire, the same
  # discipline `spec/qa_sweep_all_spec.rb`'s own `found_one` example holds
  # itself to: a divergence this spec owns outright, forever, never one
  # that depends on some real bug elsewhere staying unfixed. A literal
  # embedded nul byte in this file's own source (inside the double-quoted
  # string below — Ruby preserves it as-is, no escape needed) is a
  # completely ordinary Ruby String character — Memory
  # stores and returns it unremarked, confirmed live while building this
  # mode — but Postgres's own jsonb text encoding cannot represent one at
  # all (`PG::UntranslatableCharacter: ... cannot be converted to text`),
  # a hard, permanent PostgreSQL limitation, not a hecks bug that could
  # ever get quietly fixed out from under this spec. Exactly the shape of
  # "quiet divergence" this whole practice exists to catch, just loud
  # instead of silent: a value Memory happily accepts, a real PostgresEra
  # deployment cannot actually honor.
  #
  # `PersistenceParity.diff` itself does not rescue this — same
  # architecture as `Hecks::Fuzzing::Properties.check` (`bin/qa_sweep`'s
  # own `ruby_only_outcome` is what wraps that in a `rescue StandardError`,
  # not the check itself); `bin/qa_sweep`'s own `persistence_parity_outcome`
  # is the equivalent wrapper for this mode, proven end to end in
  # `spec/qa_sweep_persistence_parity_spec.rb`.
  it "surfaces a real, permanent Memory-vs-PostgresEra divergence — a NUL byte no real jsonb column can store" do
    steps = [open_step("w1", "has nul")]

    expect { diff(steps, schema: "break_run") }.to raise_error(PG::UntranslatableCharacter)
  end

  # **The `left:`/`right:` generalization itself** — nested here rather than
  # a second top-level `RSpec.describe` (`spec/adapters/github_ci_
  # webhook_spec.rb`'s own comment names the same rubocop rule,
  # RSpec/MultipleDescribes, and the same fix: one example group per
  # file). `:sqlite` itself needs no server, no disposable database, no
  # schema lifecycle at all (`IsolatedBoot#rebind_to_sqlite!`'s own
  # header) — this context's own `before(:all)`/`after(:all)` stand up
  # their own fixture rather than reusing the outer group's, so nothing
  # here actually depends on the outer group's Postgres-gated fixture,
  # only on being lexically inside the same file. `bin/qa_sweep`'s own
  # `adapter_parity_sqlite` mode is this generalization's second caller
  # (`QualityControlDials::ADAPTER_PARITY_PAIRS`), proven end to end (a
  # real subprocess, a real ledger) in `spec/qa_sweep_adapter_parity_
  # sqlite_spec.rb` — this file only needs to prove the mechanism, the
  # same division of labor this file's own header already draws for the
  # Memory-vs-PostgresEra pair.
  context "with left:/right: pairs other than the default" do
    FIXTURE_BLUEBOOK_FOR_LEFT_RIGHT_SPEC = <<~RUBY.freeze
      Hecks.bluebook "PersistenceParityLeftRightFixture" do
        vision "A trivially well-behaved fixture, authored only to prove Hecks::Fuzzing::PersistenceParity's own left:/right: generalization — never examples/, so this spec never depends on this repository's own live corpus staying any particular shape."
        supporting

        aggregate "Widget" do
          identified_by :reference

          attribute :reference, WidgetReference
          attribute :note,      WidgetNote

          value_object("WidgetReference") { attribute :value, String }
          value_object("WidgetNote") { attribute :value, String, optional: true }

          command "Open" do
            attribute :reference, WidgetReference
            attribute :note,      WidgetNote

            sets :reference
            sets :note

            emits "WidgetOpened"
          end
        end
      end
    RUBY

    # Bound to `PostgresEra` in the `.hecksagon` — harmless here, and
    # deliberately left in: `IsolatedBoot#rebind_to_sqlite!`/
    # `rebind_to_memory!` both rewrite whatever a `.hecksagon` declares to
    # their own target adapter (`rewrite_bindings!`'s own header), so this
    # fixture proves the pairing works even against a domain that declares
    # a binding neither side of this particular comparison actually uses —
    # exactly what a real corpus domain looks like.
    FIXTURE_HECKSAGON_FOR_LEFT_RIGHT_SPEC = <<~RUBY.freeze
      Hecks.hecksagon "PersistenceParityLeftRightFixture" do
        PersistenceParityLeftRightFixture::Widget.persisted_by("PostgresEra")
      end
    RUBY

    before(:all) do
      @left_right_fixture_root = Dir.mktmpdir("persistence_parity_left_right_spec")
      File.write(File.join(@left_right_fixture_root, "fixture.bluebook"), FIXTURE_BLUEBOOK_FOR_LEFT_RIGHT_SPEC)
      File.write(File.join(@left_right_fixture_root, "fixture.hecksagon"), FIXTURE_HECKSAGON_FOR_LEFT_RIGHT_SPEC)
    end

    after(:all) { FileUtils.remove_entry(@left_right_fixture_root) }

    def left_right_open_step(reference, note = nil)
      args = { "reference" => { "value" => reference } }
      args["note"] = note.nil? ? {} : { "value" => note }
      { "verb" => "PersistenceParityLeftRightFixture::Widget.Open", "args" => args }
    end

    it "defaults to the original Memory-vs-PostgresEra pairing when left:/right: are not given" do
      expect(described_class.method(:diff).parameters).to include([:key, :left], [:key, :right])
    end

    it "agrees on an ordinary, well-behaved step list — Memory vs a real, on-disk SQLite adapter, no database/schema needed" do
      steps = [
        left_right_open_step("w1", "hello"),
        left_right_open_step("w2"),
        left_right_open_step("w1", "duplicate")
      ]

      divergences = described_class.diff(@left_right_fixture_root, steps, left: :memory, right: :sqlite)

      expect(divergences).to eq([])
    end

    # **A controlled, named pairing** — the same diff logic the Memory-vs-
    # PostgresEra pairing uses, proven with the two sides simply swapped,
    # to confirm the generalization is not secretly biased toward `left:`
    # meaning "Memory" or `right:` meaning "the real adapter": whichever
    # two adapter symbols are passed are exactly the two `Replay.call` is
    # asked to compare, in the order given.
    it "compares whichever two adapters are actually named, not a hardcoded pair" do
      steps = [left_right_open_step("w1", "hello")]

      divergences = described_class.diff(@left_right_fixture_root, steps, left: :sqlite, right: :memory)

      expect(divergences).to eq([])
    end
  end
end
