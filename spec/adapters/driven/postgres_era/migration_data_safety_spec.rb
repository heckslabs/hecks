require "hecks"
require "hecks/ports/persistence/plugins/era"
require_relative "../../../support/postgres_probe"
require_relative "../../../support/scratch_postgres"
require_relative "../../../support/fenced_owner"
require_relative "../../../support/era_registry_loading"

# A data-loss regression in PostgresEra's migration path (H3 below),
# pinned against a real Postgres so a fix that regresses fails loudly.
#
# Listed in .github/postgres_io_spec_files.txt — moving this file must also
# update that list, or a Postgres-provisioning CI leg stops running it.
RSpec.describe "PostgresEra migration data safety", :io do
  include EraRegistryLoading

  DATA_SAFETY_DB = "hecks_era_data_safety_spec".freeze

  scratch_postgres DATA_SAFETY_DB, fenced: true

  def lineage_manager = Hecks::Adapters::PostgresEra::LineageManager

  def check!(source, translation_source: nil)
    registry = load_registry(source, translation_source: translation_source)
    lineage_manager.check!(
      registry: registry, bluebook: registry.bluebooks.values.first,
      current_text: source, settings: { database: FencedOwner.url(DATA_SAFETY_DB) }
    )
    registry
  end

  def label_of(source)
    Hecks::Runtime::StorageShape.mint_hash(load_registry(source).bluebooks.values.first)[0, 6]
  end

  def head_for(registry, aggregate_name, domain)
    aggregate = registry.bluebooks.values.first.aggregate(aggregate_name)
    Hecks::Adapters::PostgresEra.new(aggregate: aggregate, settings: { database: DATA_SAFETY_DB, domain: domain })
  end

  def instance_of(registry, aggregate_name, id, state)
    aggregate = registry.bluebooks.values.first.aggregate(aggregate_name)
    Hecks::Runtime::Instance.new(aggregate: aggregate, id: id, state: state)
  end

  def with_db
    db = PG.connect(dbname: DATA_SAFETY_DB)
    yield db
  ensure
    db&.close
  end

  def era_count(domain)
    with_db { |db| db.exec_params("SELECT count(*) FROM hecks_eras WHERE domain = $1", [domain])[0]["count"].to_i }
  end

  describe "H3 — a delete of an era-migrated record stays deleted across two mints" do
    # An `Acct` whose one free-text attribute is spelled `attribute_name`; each era renames it.
    def ledger_source(attribute_name, value_object_name)
      <<~BLUEBOOK
        Hecks.bluebook "Ledger" do
          aggregate "Acct" do
            identified_by :ref

            attribute :ref, Ref
            attribute :#{attribute_name}, #{value_object_name}

            value_object "Ref" do
              attribute :value, String
            end

            value_object "#{value_object_name}" do
              attribute :text, String
            end
          end
        end
      BLUEBOOK
    end

    let(:first_era) { ledger_source("note", "Note") }
    let(:second_era) { ledger_source("memo", "Memo") }
    let(:third_era) { ledger_source("remark", "Remark") }

    def edge(from, to, renamed_from, renamed_to)
      <<~RUBY
        Hecks.data_translation("Ledger", from: #{from.inspect}, to: #{to.inspect}) do
          aggregate("Acct") do
            rename :#{renamed_from}, to: :#{renamed_to}
          end
        end
      RUBY
    end

    def edges
      l1 = label_of(first_era)
      l2 = label_of(second_era)
      l3 = label_of(third_era)
      [edge(l1, l2, "note", "memo"), edge(l2, l3, "memo", "remark")]
    end

    def seed_era_one!
      registry = check!(first_era)
      head = head_for(registry, "Acct", "Ledger")
      %w[keep gone].each do |id|
        head.save(instance_of(registry, "Acct", id, ref: { "value" => id }, note: { "text" => "n-#{id}" }))
      end
    end

    # Seeds era 1, mints era 2, and deletes `gone` from era 2's head.
    def delete_gone_in_era_two!
      seed_era_one!
      head2 = head_for(check!(second_era, translation_source: edges[0]), "Acct", "Ledger")
      expect(head2.find("gone")).not_to be_nil # carried across the first mint
      head2.delete("gone")
    end

    it "keeps a record deleted in era 2 deleted in era 3, whose head is built on era 2's", :aggregate_failures do
      delete_gone_in_era_two!
      head3 = head_for(check!(third_era, translation_source: edges.join("\n")), "Acct", "Ledger")

      expect(head3.find("gone")).to be_nil
      expect(head3.all.map(&:id)).to eq(%w[keep])
      expect(head3.count).to eq(1)
    end

    context "with eras 1 and 2 still holding a save row for the record" do
      let(:registry3) do
        seed_era_one!
        check!(second_era, translation_source: edges[0])
        check!(third_era, translation_source: edges.join("\n"))
      end
      let(:head3) { head_for(registry3, "Acct", "Ledger") }

      it "holds the record in era 3 until it is deleted" do
        expect(head3.find("gone")).not_to be_nil
      end

      it "keeps a record deleted in era 3 deleted" do
        head3.delete("gone")

        expect(head3.find("gone")).to be_nil
      end

      it "keeps it deleted on a fresh boot's own head" do
        head3.delete("gone")

        expect(head_for(registry3, "Acct", "Ledger").find("gone")).to be_nil
      end

      it "leaves only the record that was kept" do
        head3.delete("gone")

        expect(head3.all.map(&:id)).to eq(%w[keep])
      end
    end
  end
end
