require "spec_helper"
require "tmpdir"

# The scaffold writes translations; humans resolve ambiguity. Confident
# rules are inferred only where the diff admits exactly one reading;
# everything else becomes a parse-refusing `unresolved` line — never a
# comment, never a guess. It never proposes a compute or a drop.
RSpec.describe "the translation scaffold" do
  SCAFFOLD_HELD = <<~BLUEBOOK.freeze
    Hecks.bluebook "Orders" do
      aggregate "Order" do
        identified_by :order_id

        attribute :cost,   Money
        attribute :placed, Stamp
        attribute :meta,   Meta
        attribute :info,   Info
        attribute :pen,    Pen
        attribute :extra,  Extra

        value_object "Money" do
          attribute :cents,    Integer
          attribute :currency, String
        end

        value_object "Stamp" do
          attribute :at, String
        end

        value_object "Meta" do
          attribute :origin, String
          attribute :note,   String
        end

        value_object "Info" do
          attribute :kept, String
        end

        value_object "Pen" do
          attribute :id, String
        end

        value_object "Extra" do
          attribute :tag, String
        end
      end

      aggregate "Vault" do
        identified_by :code

        attribute :code, Code

        value_object "Code" do
          attribute :value, String
        end
      end

      aggregate "Shed" do
        identified_by :roof

        attribute :roof, Roof

        value_object "Roof" do
          attribute :value, String
        end
      end
    end
  BLUEBOOK

  SCAFFOLD_CURRENT = <<~BLUEBOOK.freeze
    Hecks.bluebook "Orders" do
      aggregate "Order" do
        identified_by :order_id

        attribute :amount, Money
        attribute :placed, Timestamp
        attribute :meta,   Meta
        attribute :info,   Info
        attribute :pencil, Pencil
        attribute :stylus, Stylus

        value_object "Money" do
          attribute :cents,    Integer
          attribute :currency, String
        end

        value_object "Timestamp" do
          attribute :at, String
        end

        value_object "Meta" do
          attribute :origin, String
        end

        value_object "Info" do
          attribute :kept, String
          attribute :note, String
        end

        value_object "Pencil" do
          attribute :id, String
        end

        value_object "Stylus" do
          attribute :id, String
        end
      end

      aggregate "Strongbox" do
        identified_by :code

        attribute :code, Code

        value_object "Code" do
          attribute :value, String
        end
      end
    end
  BLUEBOOK

  def parse(source)
    registry = Hecks::Runtime::Registry.new
    loading = Hecks::Ports::Loading.bootstrap
    file = Tempfile.new(["scaffold-", ".bluebook"])
    file.write(source)
    file.flush
    Hecks.with_registry(registry) do
      loading.load_library
      Kernel.eval(source, TOPLEVEL_BINDING, file.path, 1)
    end
    registry.bluebooks.values.first
  ensure
    file&.close!
  end

  let(:diffed) { Hecks::Translation::Scaffold.diff(parse(SCAFFOLD_HELD), parse(SCAFFOLD_CURRENT)) }

  def order_rules
    diffed[:aggregates].find { |aggregate| aggregate.name == "Order" }.rules
  end

  it "infers a rename from a unique signature pair" do
    expect(order_rules).to include(kind: :rename, from: "cost", to: "amount")
  end

  it "infers a retype when only the type's own name changed" do
    expect(order_rules).to include(kind: :retype, from: "Stamp", to: "Timestamp")
  end

  it "infers a member move from a unique member-signature pair" do
    expect(order_rules).to include(kind: :move, from: "meta.note", to: "info.note")
  end

  it "writes unresolved with candidates where two readings survive" do
    unresolved = order_rules.find { |rule| rule[:kind] == :unresolved && rule[:from] == "pen" }
    expect(unresolved[:candidates].sort).to eq(%w[pencil stylus])
  end

  it "writes unresolved with no candidates where nothing explains a vanish — the arrow toward compute, or drop" do
    unresolved = order_rules.find { |rule| rule[:kind] == :unresolved && rule[:from] == "extra" }
    expect(unresolved[:candidates]).to eq([])
  end

  it "infers an aggregate rename only from an identical shape, and retired only when nothing is left unmatched" do
    strongbox = diffed[:aggregates].find { |aggregate| aggregate.name == "Strongbox" }
    expect(strongbox.was).to eq("Vault")
    expect(diffed[:retired]).to eq(["Shed"])
  end

  it "never proposes a compute or a drop" do
    kinds = diffed[:aggregates].flat_map { |aggregate| aggregate.rules.map { |rule| rule[:kind] } }.uniq
    expect(kinds - %i[rename move retype unresolved]).to be_empty
  end

  IDENTITY_HELD = <<~BLUEBOOK.freeze
    Hecks.bluebook "Roster" do
      aggregate "Person" do
        identified_by :name
        attribute :name,  PersonName
        attribute :email, PersonEmail

        value_object "PersonName" do
          attribute :value, String
        end

        value_object "PersonEmail" do
          attribute :value, String
        end
      end
    end
  BLUEBOOK

  IDENTITY_CURRENT = <<~BLUEBOOK.freeze
    Hecks.bluebook "Roster" do
      aggregate "Person" do
        identified_by :email
        attribute :name,  PersonName
        attribute :email, PersonEmail

        value_object "PersonName" do
          attribute :value, String
        end

        value_object "PersonEmail" do
          attribute :value, String
        end
      end
    end
  BLUEBOOK

  it "hints at a rekey rule when identified_by changed, even with every attribute otherwise unchanged" do
    diffed = Hecks::Translation::Scaffold.diff(parse(IDENTITY_HELD), parse(IDENTITY_CURRENT))
    rules = diffed[:aggregates].find { |aggregate| aggregate.name == "Person" }.rules

    expect(rules).to eq([{ kind: :unresolved, from: :identity, candidates: [] }])
  end

  it "renders the identity hint as an unresolved line that refuses toward rekey, not the generic message" do
    edge = Hecks::Translation::Scaffold::Edge.new(
      domain: "Roster", from: "a3f9c2", to: "b81d04", ordinal: 2, label: "b81d04",
      aggregates: Hecks::Translation::Scaffold.diff(parse(IDENTITY_HELD), parse(IDENTITY_CURRENT))[:aggregates],
      retired: []
    )
    rendered = Hecks::Translation::Scaffold.render(edge)
    expect(rendered).to include("unresolved :identity, candidates: []")

    registry = Hecks::Runtime::Registry.new
    expect do
      Hecks.with_registry(registry) { eval(rendered) }
    end.to raise_error(Hecks::Bluebook::DSL::Malformed, /Declare a rekey rule/)
  end

  it "renders a file that can only boot into a refusal while unresolved lines remain" do
    edge = Hecks::Translation::Scaffold::Edge.new(
      domain: "Orders", from: "a3f9c2", to: "b81d04", ordinal: 2, label: "b81d04",
      aggregates: diffed[:aggregates], retired: diffed[:retired]
    )
    rendered = Hecks::Translation::Scaffold.render(edge)
    expect(rendered).to include("unresolved :pen, candidates: [:pencil, :stylus]")

    registry = Hecks::Runtime::Registry.new
    expect do
      Hecks.with_registry(registry) { eval(rendered) }
    end.to raise_error(Hecks::Bluebook::DSL::Malformed, /unresolved/)
  end

  it "regenerates the file in place, matched by shape pair" do
    Dir.mktmpdir do |dir|
      edge = Hecks::Translation::Scaffold::Edge.new(
        domain: "Orders", from: "a3f9c2", to: "b81d04", ordinal: 2, label: "b81d04",
        aggregates: [], retired: ["Shed"]
      )
      first = Hecks::Translation::Scaffold.write!(dir, edge)
      expect(File.basename(first)).to eq("2-b81d04.bluebook")

      edge.retired = []
      second = Hecks::Translation::Scaffold.write!(dir, edge)
      expect(second).to eq(first)
      expect(Dir[File.join(dir, "translations", "*.bluebook")].size).to eq(1)

      other = Hecks::Translation::Scaffold::Edge.new(
        domain: "Orders", from: "b81d04", to: "c92e15", ordinal: 3, label: "c92e15",
        aggregates: [], retired: []
      )
      Hecks::Translation::Scaffold.write!(dir, other)
      expect(Dir[File.join(dir, "translations", "*.bluebook")].size).to eq(2)
    end
  end
end
