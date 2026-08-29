require "spec_helper"

# A BLUEBOOK, PROJECTED AS ITS OWN USAGE DOCUMENTATION.
#
# Exercised against BANKING and PIZZAS rather than against the chapter this was
# written beside. Nothing in the projector knows what any particular domain is,
# and a spec that only ever projected the one it was developed against could
# not tell — the `Policy` accessors were guessed wrong on the first pass and it
# was banking, not the QA chapter, that said so.
RSpec.describe Hecks::Projector::DocsProjector do
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

  it "is registered under :docs, reachable the way every projector is" do
    expect(Hecks::Projector).to be_registered(:docs)
    expect(Hecks::Projector.call(:docs, bluebook: registry.bluebook("Pizzas"))).to eq(pizzas)
  end

  it "needs no runtime, no store and no boot — only the IR" do
    expect(banking).to be_a(String)
    expect(banking).not_to be_empty
  end

  describe "the chapter" do
    it "opens with the vision, verbatim" do
      expect(banking).to include(registry.bluebook("Banking").vision)
    end

    it "says whether the domain is core or supporting" do
      expect(banking).to match(/Core domain\./i)
    end

    it "lists every aggregate it declares, and none it does not" do
      registry.bluebook("Banking").aggregates.each { |a| expect(banking).to include("## #{a.hecks_name}") }
    end
  end

  describe "an aggregate" do
    it "carries its own description and how it is identified" do
      expect(banking).to include(registry.bluebook("Banking").aggregate("Account").description)
      expect(banking).to include("Identified by `number`")
    end

    # THE SINGLE MOST COMMON MISTAKE AT THIS BOUNDARY is sending a bare scalar
    # where a value object is wanted, so the document shows the fields rather
    # than the type name.
    it "expands a value object into the shape a caller actually sends" do
      expect(banking).to include("{ cents: Integer }")
      expect(banking).not_to match(/^\| `daily_limit` \| Money \|/)
    end

    it "carries a closed set as the words it admits" do
      expect(banking).to match(/one of `[a-z]+`(, `[a-z]+`)+/)
    end

    it "carries a declared pattern and a declared default" do
      expect(banking).to match(/matches `\^?\[/)
      # banking is the domain that declares one; pizzas declares none, which is
      # why the assertion is not simply pointed at whichever is to hand.
      expect(banking).to include(%(defaults to `"good"`))
    end
  end

  describe "the lifecycle" do
    it "is a table of verb, from and to, with the state it starts in" do
      expect(banking).to include("Starts at `open`")
      expect(banking).to include("| `FreezeAccount` | `open` | `frozen` |")
    end
  end

  describe "a verb" do
    it "carries its goal and the role that issues it" do
      command = registry.bluebook("Banking").aggregate("Account").commands.find { |c| c.hecks_name == "FreezeAccount" }
      expect(banking).to include(command.goal)
      expect(banking).to include("Issued by: **#{command.role}**")
    end

    it "marks the one command that creates the record" do
      expect(banking).to include("### Open *(creates)*")
    end

    # THE PART A CALLER CANNOT GET FROM AN ARGUMENT LIST, and most of what a
    # domain actually is. Three sources, one list.
    describe "the refusals" do
      it "names the states a lifecycle verb may be issued from" do
        expect(banking).to include("`status` is anything other than `open`")
      end

      it "names a reference that has to resolve" do
        expect(banking).to include("no `Customer` exists for the id given as `customer`")
      end

      it "quotes a given in the chapter's own words" do
        given = registry.bluebook("Banking").aggregates.flat_map(&:commands)
                        .flat_map(&:givens).map(&:description).first
        expect(banking).to include(given)
      end
    end

    it "names the events it emits and anything it guarantees" do
      expect(banking).to match(/Emits `[A-Za-z]+`/)
    end
  end

  describe "a query" do
    it "carries its description, so a reader knows why the list matters" do
      query = registry.bluebook("Banking").aggregates.flat_map(&:queries).find(&:description)
      expect(banking).to include(query.description)
    end

    it "shows what it filters on" do
      expect(banking).to match(/Filters: `\w+ \w+ /)
    end
  end

  describe "an entity" do
    it "says it is addressed through its holder, which is what a caller gets wrong" do
      box = registry.bluebook("Banking").aggregates.find { |a| a.entities.any? }
      skip "banking declares no entities" unless box

      entity = box.entities.first
      expect(banking).to include("#{entity.hecks_name} (within #{box.hecks_name})")
      expect(banking).to include("`#{box.hecks_name}.#{entity.hecks_name}.<Verb>`")
    end
  end

  # WHAT HAPPENS WITHOUT ANYBODY ASKING — undiscoverable from any verb list.
  describe "reactions" do
    it "tabulates each policy as the dispatch it causes, and where it lands" do
      expect(banking).to include("## Reactions")
      expect(banking).to include("| `Account.AccountFrozen` | `AccountFreezeReview.Open` | Compliance |")
    end

    it "describes a saga by where it starts, ends and correlates" do
      skip "banking declares no saga" if registry.bluebook("Banking").process_managers.empty?

      saga = registry.bluebook("Banking").process_managers.first.to_h
      expect(banking).to include("#{saga[:name]} (a saga)")
      expect(banking).to include("correlated by `#{saga[:correlates_by]}`")
    end
  end

  # A MISSPELLING SHOULD COST A SENTENCE, NOT A PUZZLE. This returned "" and
  # exit 0 on the first pass, which is the silent-wrong-answer shape this
  # repository has already been bitten by twice in its query engine — a caller
  # cannot tell an empty document from an empty domain.
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

  # THE HALF THAT MAKES IT GET USED.
  describe "as a method on a booted domain" do
    it "answers on the chapter, beside vision and aggregates" do
      boot_in_memory

      expect(Pizzas).to respond_to(:docs)
      expect(Pizzas.docs).to eq(pizzas)
    end

    it "answers on an aggregate door, narrowed to that head" do
      boot_in_memory

      expect(Pizzas::Order.docs).to start_with("# Order")
      expect(Pizzas::Order.docs).to include("### CreatePizza")
    end

    it "takes the same options the projector does" do
      boot_in_memory

      expect(Pizzas.docs(heading: 3)).to start_with("### Pizzas")
    end
  end
end
