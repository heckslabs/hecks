require "spec_helper"
require "tmpdir"

# The boot-time era gate, for every adapter: hold the source at the
# first boot of an era, refuse loudly on structural drift an adapter
# cannot act on. Every refusal here is pinned byte-for-byte — the Rust
# era check raises the SAME strings (rust/src/runtime/era_check.rs is
# asserted against the same fixtures in its own tests).
RSpec.describe "the era check at boot" do
  ERA_FIXTURES = File.join(InMemoryDomain::ROOT, "spec", "fixtures", "eras")

  ERA_V1 = File.read(File.join(ERA_FIXTURES, "base.bluebook"))
  ERA_DRIFTED = File.read(File.join(ERA_FIXTURES, "bump_attribute_rename.bluebook"))
  ERA_BEHAVIOR_ONLY = File.read(File.join(ERA_FIXTURES, "same_behavior.bluebook"))

  def load_domain(root, source, translation_source: nil)
    domain_dir = File.join(root, "bluebook")
    # A fresh file per load: the predicate extractor caches source by
    # path, so rewriting one path with different text would hand later
    # loads stale lines.
    FileUtils.rm_rf(domain_dir)
    FileUtils.mkdir_p(domain_dir)
    @load_count = (@load_count || 0) + 1
    path = File.join(domain_dir, "shaped_#{@load_count}.bluebook")
    File.write(path, source)

    registry = Hecksagain::Runtime::Registry.new(root: root)
    loading = Hecksagain::Ports::Loading.bootstrap
    Hecksagain.with_registry(registry) do
      loading.load_library
      Kernel.eval(source, TOPLEVEL_BINDING, path, 1)
      eval(translation_source) if translation_source
    end
    [registry, domain_dir]
  end

  def check!(root, source, translation_source: nil)
    registry, domain_dir = load_domain(root, source, translation_source: translation_source)
    Hecksagain::Runtime::EraCheck.check!(registry, domain_dir)
    registry
  end

  it "holds the source text at the first boot of an era, and boots quietly ever after" do
    Dir.mktmpdir do |root|
      check!(root, ERA_V1)
      held = File.join(root, "data", "eras", "shaped", "1.bluebook")
      expect(File.read(held)).to eq(ERA_V1)

      expect { check!(root, ERA_V1) }.not_to raise_error
      expect(Dir[File.join(root, "data", "eras", "shaped", "*.bluebook")].size).to eq(1)
    end
  end

  it "never bumps on a behavior-only edit" do
    Dir.mktmpdir do |root|
      check!(root, ERA_V1)
      expect { check!(root, ERA_BEHAVIOR_ONLY) }.not_to raise_error
    end
  end

  it "refuses drift with the capability refusal, naming the era ordinal" do
    Dir.mktmpdir do |root|
      check!(root, ERA_V1)
      expect { check!(root, ERA_DRIFTED) }.to raise_error(
        Hecksagain::Runtime::WiringError,
        "cannot boot Account: the shape changed (era 2) and Memory cannot translate — bind Postgres, or reset the data"
      )
    end
  end

  it "names the minted era label once the scaffold has minted one" do
    Dir.mktmpdir do |root|
      check!(root, ERA_V1)

      drifted_registry, = load_domain(root, ERA_DRIFTED)
      drifted_bluebook = drifted_registry.bluebook("Shaped")
      store = Hecksagain::Ports::Persistence::EraStore.new(root, "Shaped")
      label = store.mint!(2, drifted_bluebook)

      expect { check!(root, ERA_DRIFTED) }.to raise_error(
        Hecksagain::Runtime::WiringError,
        "cannot boot Account: the shape changed (era 2, #{label}) and Memory cannot translate — bind Postgres, or reset the data"
      )
    end
  end

  it "recognizes a revert as the superseded era's shape, not a new era" do
    Dir.mktmpdir do |root|
      check!(root, ERA_V1)
      store = Hecksagain::Ports::Persistence::EraStore.new(root, "Shaped")
      store.hold!(2, ERA_DRIFTED)

      expect { check!(root, ERA_V1) }.to raise_error(
        Hecksagain::Runtime::WiringError,
        "cannot boot Account: this is era 1's shape, which era 2 superseded, and Memory cannot serve a superseded era — bind Postgres, or reset the data"
      )
    end
  end

  it "refuses a compute rule per-rule and by name on any non-Postgres adapter, before drift says anything vaguer" do
    Dir.mktmpdir do |root|
      translation = <<~RUBY
        Hecks.data_translation("Shaped", from: "1", to: "2") do
          aggregate("Account") { compute "price_cents", to: "price_dollars", sql: "price_cents::numeric / 100" }
        end
      RUBY

      expect { check!(root, ERA_V1, translation_source: translation) }.to raise_error(
        Hecksagain::Runtime::WiringError,
        "compute rules require the Postgres adapter; Account is bound to Memory"
      )
    end
  end

  it "refuses an edited held text and says WHICH situation the operator is in — shape change vs cosmetic" do
    Dir.mktmpdir do |root|
      check!(root, ERA_V1)
      held = File.join(root, "data", "eras", "shaped", "1.bluebook")

      # a shape-changing edit: re-attestation would refuse it, and the
      # refusal points at the archive
      File.write(held, ERA_DRIFTED)
      expect { check!(root, ERA_DRIFTED) }.to raise_error(
        Hecksagain::Runtime::WiringError,
        "cannot boot Shaped: the held text of era 1 was edited after it was frozen AND the edit changed " \
        "the storage shape — re-attestation will refuse it; restore the original text from the era archive"
      )

      # a cosmetic edit: same projection, so re-attestation is the named remedy
      File.write(held, "# an operator fixed a typo\n#{ERA_V1}")
      expect { check!(root, ERA_V1) }.to raise_error(
        Hecksagain::Runtime::WiringError,
        "cannot boot Shaped: the held text of era 1 was edited after it was frozen — the edit is cosmetic " \
        "to the storage shape; re-attest it (bin/reattest_era), or restore the original text from the era archive"
      )

      # and the archive holds the original bytes the refusals point at
      store = Hecksagain::Ports::Persistence::EraStore.new(root, "Shaped")
      archived = Dir[File.join(store.dir, "archive", "1-*.bluebook")]
      expect(archived.size).to eq(1)
      expect(File.read(archived.first)).to eq(ERA_V1)

      # restoring from the archive boots again
      File.write(held, File.read(archived.first))
      expect { check!(root, ERA_V1) }.not_to raise_error
    end
  end

  it "re-attesting an edited held text re-freezes it on the record, and boots again" do
    Dir.mktmpdir do |root|
      check!(root, ERA_V1)
      store = Hecksagain::Ports::Persistence::EraStore.new(root, "Shaped")
      File.write(store.held_path(1), ERA_DRIFTED)
      old_digest = store.stored_digest(1)

      expect { check!(root, ERA_V1) }.to raise_error(Hecksagain::Runtime::WiringError, /edited after it was frozen/)

      fresh = store.reattest!(1)
      expect(fresh).to eq(store.digest_of(ERA_DRIFTED))

      # the attestation is on the record: old digest, new digest, when
      attestation = File.read(File.join(store.dir, "attestations.tsv")).split("\t")
      expect(attestation[0]).to eq("1")
      expect(attestation[1]).to eq(old_digest)
      expect(attestation[2]).to eq(fresh)

      # and the store reads cleanly again — the re-frozen text is now
      # the held era, so the ERA_DRIFTED shape boots and ERA_V1 drifts
      expect { check!(root, ERA_DRIFTED) }.not_to raise_error
    end
  end

  it "re-attestation recomputes the era name: cosmetic edits pass, a shape change refuses hard" do
    Dir.mktmpdir do |root|
      registry, = load_domain(root, ERA_V1)
      bluebook = registry.bluebook("Shaped")
      stored_hash = Hecksagain::Runtime::StorageShape.mint_hash(bluebook)

      # comments and whitespace still project to the minted name
      cosmetic = "# an operator fixed a typo in a comment\n#{ERA_V1}"
      expect(
        Hecksagain::Translation::Reattest.shape_guard!(
          domain: "Shaped", ordinal: 1, text: cosmetic, stored_hash: stored_hash
        )
      ).to eq(:cosmetic)

      # a shape edit would retroactively redefine era 1 — no --accept
      # gets past this
      expect do
        Hecksagain::Translation::Reattest.shape_guard!(
          domain: "Shaped", ordinal: 1, text: ERA_DRIFTED, stored_hash: stored_hash
        )
      end.to raise_error(
        Hecksagain::Runtime::WiringError,
        /the edit changed the era's SHAPE, not just its text.*retroactively redefine what era 1 meant/m
      )

      # unloadable text is not attestable at all — held texts are
      # bootable source
      expect do
        Hecksagain::Translation::Reattest.shape_guard!(
          domain: "Shaped", ordinal: 1, text: "Hecks.bluebook \"Shaped\" do\n  vision \"\"\nend\n", stored_hash: stored_hash
        )
      end.to raise_error(Hecksagain::Runtime::WiringError, /does not load as a bluebook/)

      # an era that was never named cannot be shape-checked — reported,
      # not refused
      expect(
        Hecksagain::Translation::Reattest.shape_guard!(
          domain: "Shaped", ordinal: 1, text: ERA_DRIFTED, stored_hash: nil
        )
      ).to eq(:unnamed)
    end
  end

  it "the shape guard prefers the stored projection, so it survives a canonical-form change" do
    Dir.mktmpdir do |root|
      registry, = load_domain(root, ERA_V1)
      bluebook = registry.bluebook("Shaped")
      # JSON round-trip: stored projections come back string-keyed
      projection = JSON.parse(JSON.generate(Hecksagain::Runtime::StorageShape.project(bluebook)))

      # a hash minted under a DIFFERENT canonical form would no longer
      # match a recomputation — the projection comparison must win, or
      # every cosmetic edit to an old-form era false-refuses
      wrong_form_hash = "0" * 64
      cosmetic = "# an operator fixed a typo in a comment\n#{ERA_V1}"
      expect(
        Hecksagain::Translation::Reattest.shape_guard!(
          domain: "Shaped", ordinal: 1, text: cosmetic,
          stored_hash: wrong_form_hash, stored_projection: projection
        )
      ).to eq(:cosmetic)

      # and a real shape change still refuses, judged structurally
      expect do
        Hecksagain::Translation::Reattest.shape_guard!(
          domain: "Shaped", ordinal: 1, text: ERA_DRIFTED,
          stored_hash: wrong_form_hash, stored_projection: projection
        )
      end.to raise_error(
        Hecksagain::Runtime::WiringError,
        /no longer projects to the shape frozen for era 1.*retroactively redefine what era 1 meant/m
      )

      # a stored projection also lets an UNNAMED era be shape-checked —
      # strictly better than the :unnamed shrug
      expect(
        Hecksagain::Translation::Reattest.shape_guard!(
          domain: "Shaped", ordinal: 1, text: cosmetic,
          stored_hash: nil, stored_projection: projection
        )
      ).to eq(:cosmetic)
    end
  end

  it "backfills a missing integrity digest rather than refusing a pre-check store" do
    Dir.mktmpdir do |root|
      check!(root, ERA_V1)
      FileUtils.rm(File.join(root, "data", "eras", "shaped", "integrity.tsv"))

      expect { check!(root, ERA_V1) }.not_to raise_error
      expect(File.exist?(File.join(root, "data", "eras", "shaped", "integrity.tsv"))).to be(true)
    end
  end

  it "a declared-ephemeral domain iterates freely — no held texts, no drift lectures" do
    Dir.mktmpdir do |root|
      ephemeral_world = 'Hecks.world("Shaped") { persisted_by("Memory") { eras "ephemeral" } }'
      check!(root, ERA_V1, translation_source: ephemeral_world)

      expect(Dir[File.join(root, "data", "eras", "**", "*")]).to be_empty
      expect { check!(root, ERA_DRIFTED, translation_source: ephemeral_world) }.not_to raise_error
    end
  end

  it "the enforcement-grade adapter refuses to be ephemeral, in so many words" do
    Dir.mktmpdir do |root|
      wired = <<~RUBY
        Hecks.world("Shaped") { persisted_by("Postgres") { database "unused"; eras "ephemeral" } }
        Hecks.hecksagon("Shaped") do
          Shaped::Customer.persisted_by("Postgres")
          Shaped::Account.persisted_by("Postgres")
        end
      RUBY

      expect { check!(root, ERA_V1, translation_source: wired) }.to raise_error(
        Hecksagain::Runtime::WiringError,
        "Shaped binds Postgres with eras \"ephemeral\" — the enforcement-grade adapter " \
        "never forgets an era; drop the setting, or bind a file adapter for iteration"
      )
    end
  end

  it "freezes held texts forever" do
    Dir.mktmpdir do |root|
      store = Hecksagain::Ports::Persistence::EraStore.new(root, "Shaped")
      store.hold!(1, ERA_V1)
      expect { store.hold!(1, ERA_DRIFTED) }.to raise_error(
        Hecksagain::Runtime::WiringError, /frozen forever/
      )
      expect(File.read(store.held_path(1))).to eq(ERA_V1)
    end
  end

  it "mints a name once and never re-derives it" do
    Dir.mktmpdir do |root|
      registry, = load_domain(root, ERA_V1)
      bluebook = registry.bluebook("Shaped")
      store = Hecksagain::Ports::Persistence::EraStore.new(root, "Shaped")

      label = store.mint!(1, bluebook)
      expect(label).to match(/\A\h{6}\z/)

      drifted_registry, = load_domain(root, ERA_DRIFTED)
      remint = store.mint!(1, drifted_registry.bluebook("Shaped"))
      expect(remint).to eq(label)
      expect(store.label_for(1)).to eq(label)
    end
  end
end
