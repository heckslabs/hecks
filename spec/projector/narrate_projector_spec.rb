require "spec_helper"

# A BLUEBOOK, PROJECTED AS PROSE — the reader is the SME who can say whether
# it's right, not the implementer calling it, so this is exercised against
# the same two corpora `DocsProjector` is, and for the same reason: nothing
# in the projector should know what any particular domain is.
RSpec.describe Hecks::Projector::NarrateProjector do
  def corpus
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      load_bluebook_files(InMemoryDomain::BANKING_BLUEBOOK_DIR)
      Kernel.load(InMemoryDomain::PIZZAS_BLUEBOOK)
    end
    registry
  end

  let(:registry) { corpus }
  let(:banking)  { described_class.call(bluebook: registry.bluebook("Banking")) }
  let(:pizzas)   { described_class.call(bluebook: registry.bluebook("Pizzas")) }

  it "is registered under :narrate, reachable the way every projector is" do
    expect(Hecks::Projector).to be_registered(:narrate)
    expect(Hecks::Projector.call(:narrate, bluebook: registry.bluebook("Pizzas"))).to eq(pizzas)
  end

  it "needs no runtime, no store and no boot — only the IR" do
    expect(banking).to be_a(String)
    expect(banking).not_to be_empty
  end

  describe "the chapter" do
    it "opens with the vision, verbatim" do
      expect(banking).to include(registry.bluebook("Banking").vision)
    end

    it "says whether the domain is core or supporting, as a sentence" do
      expect(banking).to match(/This is a core domain\./i)
    end

    it "lists every aggregate it declares, and none it does not" do
      registry.bluebook("Banking").aggregates.each { |a| expect(banking).to include("## #{a.hecks_name}") }
    end
  end

  describe "an aggregate" do
    it "carries its own description and how it is identified, as sentences" do
      expect(banking).to include(registry.bluebook("Banking").aggregate("Account").description)
      expect(banking).to include("Every Account is identified by its `number`.")
    end

    it "says what it's linked to, in words rather than a reference type" do
      expect(banking).to match(/Each one is linked to an? Customer\./)
    end
  end

  describe "the lifecycle" do
    it "reads as a sentence per verb, naming where it starts and where each move goes" do
      expect(banking).to include("starting out at `open`")
      expect(banking).to include("**FreezeAccount** moves it from `open` to `frozen`.")
    end
  end

  describe "a verb" do
    it "carries its goal in the lede and names who issues it" do
      command = registry.bluebook("Banking").aggregate("Account").commands.find { |c| c.hecks_name == "FreezeAccount" }
      expect(banking).to include(command.goal)
      expect(banking).to match(/Issued by an? #{Regexp.escape(command.role)}\./)
    end

    # THE PART DOCSPROJECTOR'S OWN `creates?` GETS WRONG for an entity verb —
    # see `Command#acts_on`'s comment. `LedgerEntry.Amend` never creates a
    # ledger entry; it corrects one that already exists.
    it "only claims a command creates the record when it actually does" do
      expect(banking).to match(/\*\*Open\*\*.*This is how a new Account comes into being/)
      expect(banking).not_to match(/\*\*Amend\*\*.*This is how a new LedgerEntry comes into being/)
    end

    describe "what it requires" do
      it "states a lifecycle constraint positively, not as a refusal to invert" do
        expect(banking).to include("its `status` is currently `open`")
        expect(banking).not_to include("anything other than")
      end

      it "quotes a given in the chapter's own words, without the docs projector's \"not:\" prefix" do
        given = registry.bluebook("Banking").aggregates.flat_map(&:commands)
                        .flat_map(&:givens).map(&:description).first
        expect(banking).to include(given)
        expect(banking).not_to include("not: #{given}")
      end
    end

    it "names what it records as a fact" do
      expect(banking).to match(/It records `[A-Za-z]+` as a fact\./)
    end
  end

  describe "a query" do
    it "carries its description in prose" do
      query = registry.bluebook("Banking").aggregates.flat_map(&:queries).find(&:description)
      expect(banking).to include(query.description)
    end

    # THE DOUBLE-QUOTING DOCSPROJECTOR ITSELF HAS — `w[:value]` already wears
    # its own quotes or colon (`Literal.render`ed), so re-`inspect`ing it
    # prints a literal backslash. Written for readers, this must not.
    it "renders an already-quoted filter value without a second, escaped layer of quoting" do
      expect(banking).to include(%(`status` is "open"))
      expect(banking).not_to include('\\"open\\"')
    end
  end

  describe "an entity" do
    it "says it is reached through its holder, in words" do
      box = registry.bluebook("Banking").aggregates.find { |a| a.entities.any? }
      skip "banking declares no entities" unless box

      entity = box.entities.first
      expect(banking).to include("#{entity.hecks_name} (within #{box.hecks_name})")
      expect(banking).to match(/Reached through its #{box.hecks_name}/)
    end
  end

  describe "reactions" do
    it "reads a policy as a sentence: what happens, and on what" do
      expect(banking).to include("## Reactions")
      expect(banking).to include("Whenever `Account.AccountFrozen` happens, " \
                                 "`AccountFreezeReview.Open` fires on its own in Compliance")
    end

    it "describes a saga by where it starts, ends and correlates, in prose" do
      skip "banking declares no saga" if registry.bluebook("Banking").process_managers.empty?

      saga = registry.bluebook("Banking").process_managers.first.to_h
      expect(banking).to include("**#{saga[:name]}** is a saga")
      expect(banking).to include("tracked by its `#{saga[:correlates_by]}`")
    end
  end

  it "refuses an aggregate name that names nothing, and says what is there" do
    expect { described_class.call(bluebook: registry.bluebook("Banking"), options: { aggregate: "Acount" }) }
      .to raise_error(Hecks::Runtime::NotFound, /no aggregate named "Acount".*it declares .*Account/m)
  end

  describe "options" do
    it "narrows to one aggregate, dropping the chapter frame" do
      only = described_class.call(bluebook: registry.bluebook("Banking"), options: { aggregate: "Account" })

      expect(only).to start_with("# Account")
      expect(only).not_to include("## Customer")
      expect(only).not_to include("## Reactions")
    end

    it "pushes the headings down so it can be spliced into a larger document" do
      nested = described_class.call(bluebook: registry.bluebook("Pizzas"), options: { heading: 2 })

      expect(nested).to start_with("## Pizzas")
      expect(nested).to include("### Order")
    end
  end

  describe "as a method on a booted domain" do
    it "answers on the chapter, beside docs" do
      boot_in_memory

      expect(Pizzas).to respond_to(:narrate)
      expect(Pizzas.narrate).to eq(pizzas)
    end

    it "answers on an aggregate door, narrowed to that head" do
      boot_in_memory

      expect(Pizzas::Order.narrate).to start_with("# Order")
      expect(Pizzas::Order.narrate).to include("**CreatePizza**")
    end

    it "takes the same options the projector does" do
      boot_in_memory

      expect(Pizzas.narrate(heading: 3)).to start_with("### Pizzas")
    end
  end
end
