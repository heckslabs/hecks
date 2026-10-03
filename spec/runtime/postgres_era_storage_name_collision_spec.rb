require "hecks"
require "hecks/ports/persistence/plugins/era"
require "tmpdir"
require_relative "../support/postgres_probe"
require_relative "../support/fenced_owner"

# Pins a fix (ADR 0059): Lineage#head_view/#head_snapshot/#matview were
# qualified by storage_name alone, so two aggregates named alike (e.g. two
# "Note"s in different domains) derived the same physical relations, and
# PostgresEra's boot-time self-heal silently clobbered one with the other.
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

  describe "attaches from: :vendor: two fresh domains, one storage_name" do
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
          attaches "Governance"
          attaches "notes", from: :vendor

          persisted_by "PostgresEra"
        end

        Hecks.hecksagon "Notes" do
          attaches "Governance"

          persisted_by "PostgresEra"
        end

        Hecks.hecksagon "Governance" do
          Governance::RoleAssignment.persisted_by("PostgresEra")
          Governance::RoleTransition.persisted_by("PostgresEra")
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

        Hecks.world "Governance" do
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

        dispatcher = Hecks.boot(domain_dir, install_doors: false)

        dispatcher.dispatch_flat("Target::Note.Make", ref: { value: "target-owns-this" })
        dispatcher.dispatch_flat("Notes::Note.Write", ref: { value: "notes-owns-this" })

        target_rows = dispatcher.query("Target::Note.All")
        notes_rows  = dispatcher.query("Notes::Note.All")

        # Pinned: pre-fix, both domains' "Note" aggregate read and wrote
        # through the same unqualified note_head/note_head_snapshot_1
        # relations, so each query would have seen both writes.
        expect(target_rows.map { |r| r[:ref][:value] }).to eq(["target-owns-this"])
        expect(notes_rows.map { |r| r[:ref][:value] }).to eq(["notes-owns-this"])

        # One snapshot table per domain, even though both aggregates share
        # the same storage_name "note".
        snapshots = relation_names("%note_head_snapshot_1")
        expect(snapshots).to contain_exactly("target_note_head_snapshot_1", "notes_note_head_snapshot_1")

        heads = relation_names("%note_head")
        expect(heads).to contain_exactly("target_note_head", "notes_note_head")
      end
    end

    it "boots a second time without either domain clobbering the other's own physical relations" do
      Dir.mktmpdir do |dir|
        domain_dir = write_domain(dir)

        Hecks.boot(domain_dir, install_doors: false)
        dispatcher = Hecks.boot(domain_dir, install_doors: false)

        dispatcher.dispatch_flat("Target::Note.Make", ref: { value: "still-here" })
        expect(dispatcher.query("Target::Note.All").map { |r| r[:ref][:value] }).to eq(["still-here"])
      end
    end
  end

  describe "attaches: the same collision, confirmed against a real framework member (Governance)" do
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
          attaches "Governance"

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

        dispatcher = Hecks.boot(domain_dir, install_doors: false)
        registry = dispatcher.registry

        # Repository-level: building a repository never requires a role grant
        # (only dispatching a role-gated command does), so this reaches the
        # same PostgresEra#initialize self-heal path without a Governance grant.
        custodian_repo   = registry.repository("Custodian", registry.bluebook("Custodian").aggregate("RoleAssignment"))
        governance_repo  = registry.repository("Governance", registry.bluebook("Governance").aggregate("RoleAssignment"))

        custodian_repo.save(Hecks::Runtime::Instance.new(
                              aggregate: registry.bluebook("Custodian").aggregate("RoleAssignment"),
                              id: "c1", state: { ref: { "value" => "custodian-owns-this" } }
                            ))

        expect(custodian_repo.all.map { |i| i.ref.to_h }).to eq([{ value: "custodian-owns-this" }])
        # Governance's own table is untouched — pre-fix both would have
        # shared the same role_assignment_head_snapshot_1 table.
        expect(governance_repo.count).to eq(0)

        snapshots = relation_names("%role_assignment_head_snapshot_1")
        expect(snapshots).to contain_exactly("custodian_role_assignment_head_snapshot_1",
                                             "governance_role_assignment_head_snapshot_1")
      end
    end
  end

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

    # title renamed to heading: enough to change StorageShape.project's output
    # and trigger a real mint — the same minimal shape lineage_spec.rb's V1/V2 pair uses.
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

    # Every step here is needed to reproduce the live mechanism; splitting
    # this into smaller examples would leave none that actually exercises it.
    # rubocop:disable-next RSpec/ExampleLength
    it "keeps Target's own real, translated era-2 data visible after Notes' fresh era-1 self-mint boots alongside it" do
      Dir.mktmpdir do |dir|
        # LineageManager.check! only needs a registry + bluebook — no
        # hecksagon/world required to mint Target directly at era 1.
        registry_v1 = check!(TARGET_V1)
        aggregate_v1 = registry_v1.bluebooks.values.first.aggregate("Note")
        adapter_v1 = Hecks::Adapters::PostgresEra.new(
          aggregate: aggregate_v1, settings: { database: owner_url, domain: "Target", era: 1 }
        )
        adapter_v1.save(Hecks::Runtime::Instance.new(
                          aggregate: aggregate_v1, id: "n1", state: { title: { "value" => "Original Title" } }
                        ))

        # After this real translation edge, target_note_head is the compiled
        # union view, never a plain single-snapshot view again.
        from = label_of(TARGET_V1)
        to = label_of(TARGET_V2)
        check!(TARGET_V2, translation_source: edge_source(from: from, to: to))

        # Sanity: the real, compiled union already serves the translated
        # field, before Notes ever boots at all.
        db = PG.connect(dbname: STORAGE_COLLISION_DB)
        pre_boot = db.exec("SELECT state FROM target_note_head WHERE id = 'n1'")
        db.close
        expect(JSON.parse(pre_boot[0]["state"])).to eq("ref" => { "value" => "n1" }, "heading" => { "value" => "Original Title" })

        # target.bluebook is TARGET_V2, the shape hecks_eras already holds,
        # so EraResolver finds no drift when this multi-bluebook boot runs.
        write(File.join(dir, "bluebook", "target.bluebook"), TARGET_V2)
        write(
          File.join(dir, "vendor", "embryonaut_bluebooks", "notes", "bluebook", "notes.bluebook"),
          notes_bluebook
        )
        write(File.join(dir, "bluebook", "target.hecksagon"), <<~HECKSAGON)
          Hecks.hecksagon "Target" do
            attaches "Governance"
            attaches "notes", from: :vendor

            persisted_by "PostgresEra"
          end

          Hecks.hecksagon "Notes" do
            attaches "Governance"

            persisted_by "PostgresEra"
          end

          Hecks.hecksagon "Governance" do
            Governance::RoleAssignment.persisted_by("PostgresEra")
            Governance::RoleTransition.persisted_by("PostgresEra")
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

          Hecks.world "Governance" do
            persisted_by("PostgresEra") do
              database "#{owner_url}"
            end
          end
        WORLD

        # Pinned: pre-fix, Notes' era-1 self-mint (ensure_first_head!) would
        # drop and recompile the shared, unqualified note_head view back to
        # era-1 form, taking Target's already-compiled era-2 union down with it.
        dispatcher = Hecks.boot(File.join(dir, "bluebook"), install_doors: false)

        target_rows = dispatcher.query("Target::Note.All")
        expect(target_rows.map { |r| r[:heading][:value] }).to eq(["Original Title"])

        # Notes' own self-mint landed in its own relations, never Target's.
        dispatcher.dispatch_flat("Notes::Note.Write", ref: { value: "notes-owns-this" })
        expect(dispatcher.query("Notes::Note.All").map { |r| r[:ref][:value] }).to eq(["notes-owns-this"])
        expect(dispatcher.query("Target::Note.All").map { |r| r[:heading][:value] }).to eq(["Original Title"])

        # Confirms two distinct relations directly: Target's view still names
        # its era-2 matview; Notes' stays plain era-1 — neither clobbered the other.
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
