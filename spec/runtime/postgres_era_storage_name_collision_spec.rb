require "hecks"
require "hecks/ports/persistence/plugins/era"
require "tmpdir"
require_relative "../support/postgres_probe"
require_relative "../support/fenced_owner"

# The storage-name collision, found live against a real, private project
# (children-of-the-light) — a domain at era 12 of its own schema history
# (`ChildrenOfTheLight`, its own real `aggregate "Note"`) attaching a
# second, small, vendored bluebook chapter via `uses_embryonaut_bluebook
# "notes"` (`Notes`, its own unrelated `aggregate "Note"`), both bound to
# PostgresEra against the same Postgres database.
#
# **Root cause** — `Lineage#head_view`/`#head_snapshot`/`#matview`
# (postgres_era/lineage.rb) were qualified by `storage_name` alone,
# never by domain — unlike `#journal`, which already folds
# `Naming.snake(@domain)` in. Ruby's own snake-casing turns two
# different aggregates both named "Note" into the identical
# storage_name "note", so both domains' `PostgresEra` adapters derived
# the exact same physical relations (`note_head`, `note_head_snapshot_
# 1`, `note_lineage_N_<label>`) — and `PostgresEra#initialize`'s own
# unconditional, every-boot self-heal (`ensure_head_snapshot!`/
# `ensure_first_head!` — "belt-and-suspenders... at the cost of one
# CREATE TABLE IF NOT EXISTS nobody pays for twice") meant booting the
# second domain (still at era 1) dropped and recompiled the shared
# `note_head` view back to its own simple, era-1-only form — silently
# clobbering the first domain's already-compiled, higher-era union view,
# purely from an ordinary boot, no write involved at all. Confirmed live
# by hand: manually recompiling `note_head` back to its real era-12
# union form, then re-booting the same project with nothing changed on
# disk, clobbered it right back.
#
# Fixed by domain-qualifying `head_view`/`head_snapshot`/`matview` the
# same way `journal` already was (`Lineage#qualified_name`, folding in
# `Naming.snake(@domain)`, degrading to a hashed/truncated form only
# once the readable form would risk Postgres's own 63-byte identifier
# limit) — see docs/decisions/0059 for the full writeup, including the
# parallel fix this same collision needed in `rust/host` (`journal.rs`/
# `mint.rs`'s own independent copies of this naming scheme) and in
# `FieldCache#field_cache` (a fourth, differently-shaped relation family
# with the identical storage_name-only gap).
#
# Three examples, in increasing fidelity to the live report:
#   1. the straightforward case — two fresh (both era 1) domains sharing
#      a storage_name, dispatched through real commands, must never see
#      each other's writes, and must occupy genuinely distinct physical
#      relations.
#   2. the same mechanism under `uses_framework` instead of
#      `uses_embryonaut_bluebook` — nothing in `lineage.rb` ever branches
#      on how a chapter got attached, so this is expected (and confirmed)
#      to reproduce identically.
#   3. the actual reported damage — a domain already minted to a higher
#      era (a real translation edge, real historical data only visible
#      through the compiled union view) sharing a database with a fresh
#      era-1 sibling, proving an ordinary boot of the sibling no longer
#      clobbers the first domain's own already-compiled view.
RSpec.describe "PostgresEra domain-qualifies head_view/head_snapshot/matview (docs/decisions/0059)", :io do
  STORAGE_COLLISION_DB = "hecks_storage_name_collision_spec".freeze

  def owner_url = FencedOwner.url(STORAGE_COLLISION_DB)

  def write(path, content)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end

  def relation_names(pattern)
    db = PG.connect(dbname: STORAGE_COLLISION_DB)
    rows = db.exec_params(
      "SELECT table_name AS name FROM information_schema.tables WHERE table_schema = 'public' AND table_name LIKE $1 " \
      "UNION SELECT viewname AS name FROM pg_views WHERE schemaname = 'public' AND viewname LIKE $1 " \
      "UNION SELECT matviewname AS name FROM pg_matviews WHERE schemaname = 'public' AND matviewname LIKE $1",
      [pattern]
    )
    db.close
    rows.map { |row| row["name"] }
  end

  before(:all) do
    skip "no reachable Postgres — start one to run this spec" unless PostgresProbe.available?

    admin = PG.connect(dbname: "postgres")
    admin.exec("DROP DATABASE IF EXISTS #{STORAGE_COLLISION_DB} WITH (FORCE)")
    admin.exec("CREATE DATABASE #{STORAGE_COLLISION_DB}")
    admin.close
    FencedOwner.own!(STORAGE_COLLISION_DB)
  end

  after(:all) do
    admin = PG.connect(dbname: "postgres")
    admin.exec("DROP DATABASE IF EXISTS #{STORAGE_COLLISION_DB} WITH (FORCE)")
    admin.close
  end

  before do
    scrub = PG.connect(dbname: STORAGE_COLLISION_DB)
    scrub.exec("DROP SCHEMA public CASCADE")
    scrub.exec("CREATE SCHEMA public")
    scrub.close
    FencedOwner.own_public!(STORAGE_COLLISION_DB)
  end

  # ── 1: uses_embryonaut_bluebook — the live report's own attachment mechanism ──

  describe "uses_embryonaut_bluebook: two fresh domains, one storage_name" do
    def target_bluebook
      <<~BLUEBOOK
        Hecks.bluebook "Target" do
          vision "the domain that attaches a second, vendored bluebook sharing an aggregate name"
          core

          aggregate "Note" do
            description "Target's own, pre-existing Note"
            identified_by :ref

            value_object "Ref" do
              attribute :value, String
              invariant("a note has a ref") { !value.to_s.empty? }
            end

            attribute :ref, Ref

            command "Make" do
              role "Someone"
              goal "make Target's own note"
              attribute :ref, Ref
              emits "NoteMade"
            end

            query "All" do
            end
          end
        end
      BLUEBOOK
    end

    def notes_bluebook
      <<~BLUEBOOK
        Hecks.bluebook "Notes" do
          vision "a tiny vendored chapter whose own aggregate collides with Target's own storage_name"
          core

          aggregate "Note" do
            description "Notes' own, entirely unrelated Note"
            identified_by :ref

            value_object "Ref" do
              attribute :value, String
              invariant("a note has a ref") { !value.to_s.empty? }
            end

            attribute :ref, Ref

            command "Write" do
              role "Someone"
              goal "write Notes' own note"
              attribute :ref, Ref
              emits "NoteWritten"
            end

            query "All" do
            end
          end
        end
      BLUEBOOK
    end

    def write_domain(dir)
      write(File.join(dir, "bluebook", "target.bluebook"), target_bluebook)
      write(
        File.join(dir, "vendor", "embryonaut_bluebooks", "notes", "bluebook", "notes.bluebook"),
        notes_bluebook
      )
      write(File.join(dir, "bluebook", "target.hecksagon"), <<~HECKSAGON)
        Hecks.hecksagon "Target" do
          uses_framework "Governance"
          uses_embryonaut_bluebook "notes"

          persisted_by "PostgresEra"
        end

        Hecks.hecksagon "Notes" do
          uses_framework "Governance"

          persisted_by "PostgresEra"
        end
      HECKSAGON
      write(File.join(dir, "bluebook", "target.world"), <<~WORLD)
        Hecks.world "Target" do
          persisted_by("PostgresEra") do
            database "#{owner_url}"
          end
        end

        Hecks.world "Notes" do
          persisted_by("PostgresEra") do
            database "#{owner_url}"
          end
        end
      WORLD
      File.join(dir, "bluebook")
    end

    it "keeps Target::Note's and Notes::Note's own writes apart, and occupies genuinely distinct physical relations" do
      Dir.mktmpdir do |dir|
        domain_dir = write_domain(dir)

        dispatcher = Hecks.boot(domain_dir, install_facade: false)

        dispatcher.dispatch("Target::Note.Make", ref: { value: "target-owns-this" })
        dispatcher.dispatch("Notes::Note.Write", ref: { value: "notes-owns-this" })

        target_rows = dispatcher.query("Target::Note.All")
        notes_rows  = dispatcher.query("Notes::Note.All")

        # **The bug, pinned**: pre-fix, both domains' "Note" aggregate read
        # and wrote through the same unqualified "note_head"/
        # "note_head_snapshot_1" relations, so each domain's own query
        # would have seen both writes.
        expect(target_rows.map { |r| r[:ref][:value] }).to eq(["target-owns-this"])
        expect(notes_rows.map { |r| r[:ref][:value] }).to eq(["notes-owns-this"])

        # **Domain-qualified, not shared** — one snapshot table per domain,
        # even though both aggregates share the exact same storage_name
        # "note".
        snapshots = relation_names("%note_head_snapshot_1")
        expect(snapshots).to contain_exactly("target_note_head_snapshot_1", "notes_note_head_snapshot_1")

        heads = relation_names("%note_head")
        expect(heads).to contain_exactly("target_note_head", "notes_note_head")
      end
    end

    it "boots a second time without either domain clobbering the other's own physical relations" do
      Dir.mktmpdir do |dir|
        domain_dir = write_domain(dir)

        Hecks.boot(domain_dir, install_facade: false)
        dispatcher = Hecks.boot(domain_dir, install_facade: false)

        dispatcher.dispatch("Target::Note.Make", ref: { value: "still-here" })
        expect(dispatcher.query("Target::Note.All").map { |r| r[:ref][:value] }).to eq(["still-here"])
      end
    end
  end

  # ── 2: uses_framework — the same mechanism, a different attachment path ──
  #
  # `lineage.rb`'s own naming helpers never branch on how a chapter got
  # attached — `uses_framework`/`uses_embryonaut_bluebook` both just add
  # a bluebook to the same registry, and `PostgresEra#initialize`
  # resolves `@domain` from the aggregate's own owning chapter name
  # either way (postgres_era.rb's own comment on `@domain`). So a
  # `uses_framework "Governance"` domain whose own aggregate happens to
  # share a storage_name with one of Governance's real aggregates
  # ("RoleAssignment") is expected to reproduce the identical collision
  # — confirmed directly here, at the repository level (no command
  # dispatch/role-grant machinery needed: a repository is built the same
  # way whether or not anything ever authorizes a command against it).

  describe "uses_framework: the same collision, confirmed against a real framework member (Governance)" do
    def custodian_bluebook
      <<~BLUEBOOK
        Hecks.bluebook "Custodian" do
          vision "a domain whose own aggregate happens to share a name with one of Governance's own"
          core

          aggregate "RoleAssignment" do
            description "Custodian's own, entirely unrelated RoleAssignment"
            identified_by :ref

            value_object "Ref" do
              attribute :value, String
              invariant("has a ref") { !value.to_s.empty? }
            end

            attribute :ref, Ref

            query "All" do
            end
          end
        end
      BLUEBOOK
    end

    def write_domain(dir)
      write(File.join(dir, "bluebook", "custodian.bluebook"), custodian_bluebook)
      write(File.join(dir, "bluebook", "custodian.hecksagon"), <<~HECKSAGON)
        Hecks.hecksagon "Custodian" do
          uses_framework "Governance"

          persisted_by "PostgresEra"
        end

        Hecks.hecksagon "Governance" do
          Governance::RoleAssignment.persisted_by("PostgresEra")
          Governance::RoleTransition.persisted_by("PostgresEra")
        end
      HECKSAGON
      write(File.join(dir, "bluebook", "custodian.world"), <<~WORLD)
        Hecks.world "Custodian" do
          persisted_by("PostgresEra") do
            database "#{owner_url}"
          end
        end

        Hecks.world "Governance" do
          persisted_by("PostgresEra") do
            database "#{owner_url}"
          end
        end
      WORLD
      File.join(dir, "bluebook")
    end

    it "gives Custodian::RoleAssignment and Governance::RoleAssignment genuinely distinct physical relations" do
      Dir.mktmpdir do |dir|
        domain_dir = write_domain(dir)

        dispatcher = Hecks.boot(domain_dir, install_facade: false)
        registry = dispatcher.registry

        # Repository-level, deliberately — building a repository never
        # requires an actual role GRANT to exist (only dispatching a
        # role-gated command does), so this reaches the exact same
        # `PostgresEra#initialize` self-heal path the live bug hit
        # without needing to bootstrap a real Governance admin grant.
        custodian_repo   = registry.repository("Custodian", registry.bluebook("Custodian").aggregate("RoleAssignment"))
        governance_repo  = registry.repository("Governance", registry.bluebook("Governance").aggregate("RoleAssignment"))

        custodian_repo.save(Hecks::Runtime::Instance.new(
                              aggregate: registry.bluebook("Custodian").aggregate("RoleAssignment"),
                              id: "c1", state: { ref: { "value" => "custodian-owns-this" } }
                            ))

        expect(custodian_repo.all.map { |i| i.ref.to_h }).to eq([{ value: "custodian-owns-this" }])
        # Governance's own real RoleAssignment table is untouched by
        # Custodian's write — pre-fix, both would have shared the exact
        # same "role_assignment_head_snapshot_1" table.
        expect(governance_repo.count).to eq(0)

        snapshots = relation_names("%role_assignment_head_snapshot_1")
        expect(snapshots).to contain_exactly("custodian_role_assignment_head_snapshot_1",
                                             "governance_role_assignment_head_snapshot_1")
      end
    end
  end

  # ── 3: the actual reported damage — a higher-era domain's own already-
  # compiled view, clobbered by an ordinary boot of a colliding sibling ──

  describe "a fresh sibling's own boot no longer clobbers an already-minted, higher-era domain's own head view" do
    TARGET_V1 = <<~BLUEBOOK.freeze
      Hecks.bluebook "Target" do
        vision "the domain that attaches a second, vendored bluebook sharing an aggregate name"
        core

        aggregate "Note" do
          description "Target's own, pre-existing Note"
          identified_by :ref

          value_object "Ref" do
            attribute :value, String
            invariant("a note has a ref") { !value.to_s.empty? }
          end

          value_object "Title" do
            attribute :value, String
          end

          attribute :ref, Ref
          attribute :title, Title

          command "Make" do
            role "Someone"
            goal "make Target's own note"
            attribute :ref, Ref
            attribute :title, Title
            emits "NoteMade"
          end

          query "All" do
          end
        end
      end
    BLUEBOOK

    # **The shape change** — `title` renamed to `heading`, enough to change
    # `StorageShape.project`'s own output and trigger a real mint,
    # exactly the minimal shape `lineage_spec.rb`'s own V1/V2 pair uses.
    TARGET_V2 = <<~BLUEBOOK.freeze
      Hecks.bluebook "Target" do
        vision "the domain that attaches a second, vendored bluebook sharing an aggregate name"
        core

        aggregate "Note" do
          description "Target's own, pre-existing Note"
          identified_by :ref

          value_object "Ref" do
            attribute :value, String
            invariant("a note has a ref") { !value.to_s.empty? }
          end

          value_object "Title" do
            attribute :value, String
          end

          attribute :ref, Ref
          attribute :heading, Title

          command "Make" do
            role "Someone"
            goal "make Target's own note"
            attribute :ref, Ref
            attribute :heading, Title
            emits "NoteMade"
          end

          query "All" do
          end
        end
      end
    BLUEBOOK

    def notes_bluebook
      <<~BLUEBOOK
        Hecks.bluebook "Notes" do
          vision "a tiny vendored chapter whose own aggregate collides with Target's own storage_name"
          core

          aggregate "Note" do
            description "Notes' own, entirely unrelated Note"
            identified_by :ref

            value_object "Ref" do
              attribute :value, String
              invariant("a note has a ref") { !value.to_s.empty? }
            end

            attribute :ref, Ref

            command "Write" do
              role "Someone"
              goal "write Notes' own note"
              attribute :ref, Ref
              emits "NoteWritten"
            end

            query "All" do
            end
          end
        end
      BLUEBOOK
    end

    def edge_source(from:, to:)
      <<~RUBY
        Hecks.data_translation("Target", from: #{from.inspect}, to: #{to.inspect}) do
          aggregate("Note") do
            rename :title, to: :heading
          end
        end
      RUBY
    end

    def load_registry(source, translation_source: nil)
      registry = Hecks::Runtime::Registry.new
      loading = Hecks::Ports::Loading.bootstrap
      file = Tempfile.new(["target-", ".bluebook"])
      file.write(source)
      file.flush
      Hecks.with_registry(registry) do
        loading.load_library
        Kernel.eval(source, TOPLEVEL_BINDING, file.path, 1)
        eval(translation_source) if translation_source
      end
      registry
    ensure
      file&.close!
    end

    def check!(source, translation_source: nil)
      registry = load_registry(source, translation_source: translation_source)
      bluebook = registry.bluebooks.values.first
      Hecks::Adapters::PostgresEra::LineageManager.check!(
        registry: registry, bluebook: bluebook, current_text: source, settings: { database: owner_url }
      )
      registry
    end

    def label_of(source)
      Hecks::Runtime::StorageShape.mint_hash(load_registry(source).bluebooks.values.first)[0, 6]
    end

    # The full end-to-end reproduction — era-1 mint, a real era-2
    # translation, then the ordinary multi-bluebook boot that used to
    # clobber it — genuinely needs every step below to mean anything;
    # splitting it would leave no single example that reproduces the
    # live bug's own actual mechanism.
    # rubocop:disable-next RSpec/ExampleLength
    it "keeps Target's own real, translated era-2 data visible after Notes' fresh era-1 self-mint boots alongside it" do
      Dir.mktmpdir do |dir|
        # ── era 1: mint Target directly (no hecksagon/world involved —
        # LineageManager.check! only needs a registry + bluebook), then
        # write one real record through Target's own generic write path ──
        registry_v1 = check!(TARGET_V1)
        aggregate_v1 = registry_v1.bluebooks.values.first.aggregate("Note")
        adapter_v1 = Hecks::Adapters::PostgresEra.new(
          aggregate: aggregate_v1, settings: { database: owner_url, domain: "Target", era: 1 }
        )
        adapter_v1.save(Hecks::Runtime::Instance.new(
                          aggregate: aggregate_v1, id: "n1", state: { title: { "value" => "Original Title" } }
                        ))

        # ── era 2: a real translation edge, mint straight through —
        # Target's own "target_note_head" is now the compiled, chained-
        # edge union view lineage_spec.rb's own suite proves elsewhere,
        # never a plain single-snapshot view again ──
        from = label_of(TARGET_V1)
        to = label_of(TARGET_V2)
        check!(TARGET_V2, translation_source: edge_source(from: from, to: to))

        # Sanity: the real, compiled union already serves the translated
        # field, before Notes ever boots at all.
        db = PG.connect(dbname: STORAGE_COLLISION_DB)
        pre_boot = db.exec("SELECT state FROM target_note_head WHERE id = 'n1'")
        db.close
        expect(JSON.parse(pre_boot[0]["state"])).to eq("ref" => { "value" => "n1" }, "heading" => { "value" => "Original Title" })

        # ── now write the real multi-bluebook project directory — target.bluebook
        # is TARGET_V2 (the shape `hecks_eras` already holds as current,
        # so this boot's own EraResolver finds no drift), plus the
        # vendored Notes chapter, sharing Target's own storage_name ──
        write(File.join(dir, "bluebook", "target.bluebook"), TARGET_V2)
        write(
          File.join(dir, "vendor", "embryonaut_bluebooks", "notes", "bluebook", "notes.bluebook"),
          notes_bluebook
        )
        write(File.join(dir, "bluebook", "target.hecksagon"), <<~HECKSAGON)
          Hecks.hecksagon "Target" do
            uses_framework "Governance"
            uses_embryonaut_bluebook "notes"

            persisted_by "PostgresEra"
          end

          Hecks.hecksagon "Notes" do
            uses_framework "Governance"

            persisted_by "PostgresEra"
          end
        HECKSAGON
        write(File.join(dir, "bluebook", "target.world"), <<~WORLD)
          Hecks.world "Target" do
            persisted_by("PostgresEra") do
              database "#{owner_url}"
            end
          end

          Hecks.world "Notes" do
            persisted_by("PostgresEra") do
              database "#{owner_url}"
            end
          end
        WORLD

        # **The moment the live bug happened** — an ordinary boot of the
        # multi-bluebook registry. Notes has never been minted before,
        # so its own `PostgresEra#initialize` self-mints era 1 for
        # its own "note" storage_name — pre-fix, `ensure_first_head!`
        # would drop and recompile the shared (unqualified) "note_head"
        # view back to Notes' own simple era-1 form, taking Target's
        # real, compiled era-2 union down with it.
        dispatcher = Hecks.boot(File.join(dir, "bluebook"), install_facade: false)

        # Target's own real data is still there, still correctly
        # translated — the actual claim the live bug's own field report
        # made about children-of-the-light's real historical notes.
        target_rows = dispatcher.query("Target::Note.All")
        expect(target_rows.map { |r| r[:heading][:value] }).to eq(["Original Title"])

        # Notes' own boot-time self-mint happened, genuinely — it just
        # landed in its own physical relations, never Target's.
        dispatcher.dispatch("Notes::Note.Write", ref: { value: "notes-owns-this" })
        expect(dispatcher.query("Notes::Note.All").map { |r| r[:ref][:value] }).to eq(["notes-owns-this"])
        # ...and Target's own query is still untouched by that write.
        expect(dispatcher.query("Target::Note.All").map { |r| r[:heading][:value] }).to eq(["Original Title"])

        # **Direct SQL, the sharpest possible confirmation**: two distinct
        # physical relations, Target's own still the compiled union
        # (its definition still names its own era-2 matview), Notes'
        # own the plain era-1 form — neither clobbered the other's.
        db = PG.connect(dbname: STORAGE_COLLISION_DB)
        target_def = db.exec_params("SELECT definition FROM pg_views WHERE viewname = $1", ["target_note_head"])[0]["definition"]
        notes_def = db.exec_params("SELECT definition FROM pg_views WHERE viewname = $1", ["notes_note_head"])[0]["definition"]
        db.close

        expect(target_def).to include("target_note_lineage_2_")
        expect(notes_def).not_to include("lineage")
      end
    end
  end
end
