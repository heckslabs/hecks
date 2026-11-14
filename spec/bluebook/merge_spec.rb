require "spec_helper"
require "hecks/bluebook/merge"

RSpec.describe Hecks::Bluebook::Merge do
  # Scratch sources only: the merge parses text and never loads a domain.
  let(:bluebook) do
    <<~BLUEBOOK
      Hecks.bluebook "Shop" do
        aggregate "Order" do
          # What the order costs.
          attribute :total, Integer
          identified_by :total

          value_object "Count" do
            attribute :value, Integer
            invariant("a count is not negative") { !value.negative? }
          end

          command "Place" do
            role "Clerk"
            emits OrderPlaced
          end
        end
      end
    BLUEBOOK
  end

  let(:hecksagon) do
    <<~HECKSAGON
      Hecks.hecksagon "Shop" do
        attaches "Governance"
        persisted_by "Memory"
      end
    HECKSAGON
  end

  let(:world) do
    <<~WORLD
      Hecks.world "Shop" do
        realm "Examples"
      end
    WORLD
  end

  def cancel = "\n    command \"Cancel\" do\n      role \"Clerk\"\n    end\n"

  def ship = "\n    command \"Ship\" do\n      role \"Courier\"\n    end\n"

  def place_end = "      emits OrderPlaced\n    end\n"

  def place = "\n    command \"Place\" do\n      role \"Clerk\"\n#{place_end}"

  def invariant = "      invariant(\"a count is not negative\") { !value.negative? }\n"

  # One branch's version of a source: `from` replaced by `to`, which must be there to replace.
  def change(source, from, to)
    raise ArgumentError, "#{from.inspect} is not in the source" unless source.include?(from)

    source.sub(from) { to }
  end

  def merge(base, ours, theirs) = described_class.call(base: base, ours: ours, theirs: theirs)

  def conflicts(base, ours, theirs) = merge(base, ours, theirs).conflicts.map(&:to_s)

  describe "two branches that change different members" do
    it "keeps a command each branch added to one aggregate", :aggregate_failures do
      merged = merge(bluebook, change(bluebook, place_end, place_end + cancel), change(bluebook, place_end, place_end + ship))
      expect(merged).to be_clean
      expect(merged.text).to eq(change(bluebook, place_end, place_end + ship + cancel))
    end

    it "keeps one branch's attribute change and the other's new command" do
      ours = change(bluebook, "attribute :total, Integer", "attribute :total, Float")
      merged = merge(bluebook, ours, change(bluebook, place_end, place_end + ship))
      expect(merged.text).to eq(change(ours, place_end, place_end + ship))
    end

    it "keeps an invariant each branch added to one value object", :aggregate_failures do
      ours = change(bluebook, invariant, "#{invariant}      invariant(\"small\") { value < 10 }\n")
      theirs = change(bluebook, invariant, "#{invariant}      invariant(\"even\") { value.even? }\n")
      expect(merge(bluebook, ours, theirs).text).to include("invariant(\"small\")", "invariant(\"even\")")
    end

    it "takes once a change both branches made alike" do
      same = change(bluebook, "role \"Clerk\"", "role \"Boss\"")
      expect(merge(bluebook, same, same).text).to eq(same)
    end

    it "removes a member one branch removed and the other left alone" do
      ours = change(bluebook, place, "")
      expect(merge(bluebook, ours, change(bluebook, "Integer\n    identified_by", "Float\n    identified_by")).text)
        .to eq(change(ours, "attribute :total, Integer", "attribute :total, Float"))
    end

    it "carries the comment above a member with it" do
      theirs = change(bluebook, "    identified_by", "    # Who placed it.\n    attribute :clerk, String\n    identified_by")
      ours = change(bluebook, "role \"Clerk\"", "role \"Boss\"")
      expect(merge(bluebook, ours, theirs).text).to include("    # Who placed it.\n    attribute :clerk, String\n")
    end

    it "answers text that parses" do
      merged = merge(bluebook, change(bluebook, place_end, place_end + cancel), change(bluebook, place_end, place_end + ship))
      expect(Prism.parse(merged.text)).to be_success
    end
  end

  describe "two branches that change the same member" do
    it "names an attribute both changed by aggregate and member" do
      ours = change(bluebook, "attribute :total, Integer", "attribute :total, Float")
      theirs = change(bluebook, "attribute :total, Integer", "attribute :total, String")
      expect(conflicts(bluebook, ours, theirs)).to eq(["Order.total: attribute changed on both branches"])
    end

    it "names an invariant both changed" do
      ours = change(bluebook, "!value.negative?", "value >= 0")
      theirs = change(bluebook, "!value.negative?", "value > -1")
      expect(conflicts(bluebook, ours, theirs))
        .to eq(["Order.Count: invariant \"a count is not negative\" changed on both branches"])
    end

    it "names a nameless value both changed by the command that holds it" do
      ours = change(bluebook, "role \"Clerk\"", "role \"Boss\"")
      theirs = change(bluebook, "role \"Clerk\"", "role \"Owner\"")
      expect(conflicts(bluebook, ours, theirs)).to eq(["Order.Place: role \"Boss\" changed on both branches"])
    end

    it "names a command one branch removed and the other changed" do
      theirs = change(bluebook, "role \"Clerk\"", "role \"Boss\"")
      expect(conflicts(bluebook, change(bluebook, place, ""), theirs))
        .to eq(["Order.Place: command removed on one branch and changed on the other"])
    end

    it "names a command both branches added under one name" do
      theirs = change(bluebook, place_end, place_end + change(cancel, "Clerk", "Boss"))
      expect(conflicts(bluebook, change(bluebook, place_end, place_end + cancel), theirs))
        .to eq(["Order.Cancel: command added differently on both branches"])
    end

    it "holds the aggregate, the member and each branch's text", :aggregate_failures do
      ours = change(bluebook, "attribute :total, Integer", "attribute :total, Float")
      conflict = merge(bluebook, ours, change(bluebook, "attribute :total, Integer", "attribute :total, String")).conflicts.first
      expect(conflict.to_h).to include(kind: :both_changed, word: "attribute", name: "total")
      expect(conflict.aggregate).to eq("Order")
      expect(conflict.theirs).to eq("    # What the order costs.\n    attribute :total, String\n")
    end

    it "refuses to answer text, naming the conflict" do
      ours = change(bluebook, "attribute :total, Integer", "attribute :total, Float")
      merged = merge(bluebook, ours, change(bluebook, "attribute :total, Integer", "attribute :total, String"))
      expect { merged.text }.to raise_error(described_class::Conflicted, /Order\.total: attribute changed/)
    end
  end

  describe "a hecksagon" do
    it "keeps an attachment each branch added" do
      ours = change(hecksagon, "  persisted_by", "  attaches \"Identity\"\n  persisted_by")
      theirs = change(hecksagon, "  persisted_by", "  attaches \"Privacy\"\n  persisted_by")
      expect(merge(hecksagon, ours, theirs).text).to include("attaches \"Identity\"", "attaches \"Privacy\"")
    end

    it "names a store both branches changed" do
      ours = change(hecksagon, "\"Memory\"", "\"Sqlite\"")
      expect(conflicts(hecksagon, ours, change(hecksagon, "\"Memory\"", "\"Heki\"")))
        .to eq(["Shop: persisted_by \"Sqlite\" changed on both branches"])
    end
  end

  describe "a world" do
    it "names a setting both branches changed" do
      ours = change(world, "Examples", "Demos")
      expect(conflicts(world, ours, change(world, "Examples", "Samples")))
        .to eq(["Shop: realm \"Demos\" changed on both branches"])
    end

    it "names a setting each branch added with another value" do
      ours = change(world, "end", "  launcher \"Launcher\"\nend")
      expect(conflicts(world, ours, change(world, "end", "  launcher \"Console\"\nend")))
        .to eq(["Shop: launcher \"Launcher\" added differently on both branches"])
    end

    it "keeps settings the branches added under different words" do
      ours = change(world, "end", "  launcher \"Launcher\"\nend")
      expect(merge(world, ours, change(world, "end", "  work_limit 3\nend")).text).to include("launcher", "work_limit 3")
    end
  end

  describe "the repository's own files" do
    def source(path) = File.read(File.expand_path("../../#{path}", __dir__))

    %w[
      lib/hecks/hecks/deliver/deliver.bluebook
      lib/hecks/framework/bluebook/framework.hecksagon
      examples/pizzas/bluebook/pizzas.world
    ].each do |path|
      it "outlines #{path} into members that read back as the file" do
        expect(described_class::Outline.call(source(path)).text).to eq(source(path))
      end
    end

    it "names a conflict in a large bluebook by its aggregate and member" do
      deliver = source("lib/hecks/hecks/deliver/deliver.bluebook")
      line = "attribute :landed,   Word,   optional: true"
      ours, theirs = %w[Word Report].map { |type| change(deliver, line, "attribute :landed, #{type}") }
      expect(conflicts(deliver, ours, theirs)).to eq(["Integration.landed: attribute changed on both branches"])
    end
  end

  it "refuses a text that does not parse, naming the side" do
    expect { merge(world, world, "Hecks.world \"Shop\" do\n") }
      .to raise_error(described_class::Unreadable, /\Atheirs does not parse/)
  end
end
