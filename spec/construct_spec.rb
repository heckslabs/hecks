
require "spec_helper"

# A CONSTRUCT IS A RUBY CLASS, AND WHAT POINTS AT ONE IS AN EDGE.
#
# Value objects crossed over first: `ValueObjectBuilder` returns a subclass of
# `IR::ValueObject` nested where the bluebook nests it, so `Pizzas::Pizza::Price`
# is a real constant and Ruby's constant tree is the index — which is why
# `Aggregate#value_object(name)` is on its way out rather than reimplemented.
#
# `reference_to Customer` followed. It used to mint the STRING
# "Reference<Customer>" from a constant just handed in, and five readers parsed
# that spelling back apart. It holds an `IR::Reference` now, which RESOLVES to
# the aggregate class through the chapter.
#
# The reason the declared name is carried beside `Class#name` rather than
# replacing it is here as an assertion rather than an argument: three aggregates
# in banking each declare their own `Narrative`.
RSpec.describe "a construct's identity" do
  CONSTRUCT_PIZZAS  = InMemoryDomain::PIZZAS_BLUEBOOK
  CONSTRUCT_BANKING = File.join(InMemoryDomain::ROOT, "examples/banking/bluebook/banking.bluebook").freeze

  # The house pattern — load into a fresh registry against the Memory adapter, so
  # no example touches a data directory. `Hecks.boot` on a real example domain
  # would bind Heki and write to disk.
  def boot(bluebook)
    registry = Hecksagain::Runtime::Registry.new

    Hecksagain.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Kernel.load(bluebook)
      Hecksagain::Runtime::Loader.bind_runtime(
        Hecksagain::Runtime::Dispatcher.new(registry)
      )
    end
  end

  # Memoised per example ON PURPOSE. Every load mints a fresh class graph and
  # repoints the top-level constant at the newest, so two loads in one example
  # yield two different `Price` classes.
  def pizzas  = @pizzas  ||= boot(CONSTRUCT_PIZZAS)
  def banking = @banking ||= boot(CONSTRUCT_BANKING)

  def aggregate_class(runtime, domain, name)
    runtime.registry.bluebook(domain).aggregate(name).ruby_class
  end

  def pizza = aggregate_class(pizzas, "Pizzas", "Pizza")

  describe "the name it is declared by" do
    it "spells an aggregate the way the aggregate already spelled itself" do
      # `Aggregate.fqn` predates the mixin and computes "#{domain}::#{ir.name}".
      # If these ever disagree there are two identities for one construct, which
      # is what the invisible field exists to prevent.
      expect(pizza.hecks_fqn).to eq(pizza.fqn)
      expect(pizza.hecks_fqn).to eq("Pizzas::Pizza")
    end

    it "spells a value object the way the meta-domain already ids one" do
      # `MetaValidator::Judge#identify` mints "#{parent_id}.#{name}" for every
      # category below an aggregate. Same string, reached from the class graph
      # instead of from a walk — so a construct and the language's record OF that
      # construct need no translation between them.
      expect(pizza::Price.hecks_fqn).to eq("Pizzas::Pizza.Price")
    end

    it "leaves Class#name telling the truth about where the class lives" do
      expect(pizza::Price.name).to eq("Pizzas::Pizza::Price")
      expect(pizza::Price.hecks_name).to eq("Price")
    end

    it "reaches a value object as a nested constant, with no lookup at all" do
      expect(pizza.const_get(:Price)).to be(pizza::Price)
      expect(pizza::Price).to be_a(Class)
      expect(pizza::Price.attributes.map(&:name)).to eq([:cents])
    end

    it "keeps three same-named value objects distinguishable" do
      shapes = %w[Account ATMCard Transfer].map do |owner|
        aggregate_class(banking, "Banking", owner)::Narrative
      end

      expect(shapes.uniq.size).to eq(3)
      expect(shapes.map(&:hecks_name)).to eq(%w[Narrative Narrative Narrative])
      expect(shapes.map(&:hecks_fqn)).to eq(
        ["Banking::Account.Narrative", "Banking::ATMCard.Narrative", "Banking::Transfer.Narrative"]
      )
    end
  end

  describe "a reference as an edge" do
    def references_in(runtime, domain)
      runtime.registry.bluebook(domain).aggregates.flat_map do |aggregate|
        lists = [[aggregate.name, aggregate.attributes]] +
                aggregate.commands.map { |command| ["#{aggregate.name}.#{command.name}", command.attributes] }
        lists.flat_map do |owner, attributes|
          attributes.select(&:reference?).map { |attribute| [owner, attribute] }
        end
      end
    end

    # THE GATE THAT WAS MISSING. `resolve_references` SKIPS a nil target — a
    # cross-domain reference may legitimately not be loaded — so a `resolve` that
    # answered nil for everything would leave the whole suite green while the one
    # guarantee an aggregate reference is for quietly stopped holding. Which is
    # precisely how it came to be declared fourteen times and enforced nowhere.
    it "resolves every reference in banking to a class in its own chapter" do
      found = references_in(banking, "Banking")

      expect(found.size).to eq(16)
      found.each do |owner, attribute|
        resolved = attribute.type.resolve

        expect(resolved).to be_a(Class), "#{owner}##{attribute.name} resolved to #{resolved.inspect}"
        expect(resolved.hecks_name).to eq(attribute.type.target_name)
        expect(resolved.hecks_owner.hecks_name).to eq("Banking")
      end
    end

    it "still refuses a reference that points at nothing" do
      expect {
        banking.dispatch("Banking::Account.Open", customer_id: "nobody-registered-this",
                                                  number: { value: "ACC-1" },
                                                  kind: { name: "current" },
                                                  daily_limit: { cents: 100 })
      }.to raise_error(Hecksagain::Runtime::NotFound, /no Customer with/)
    end

    it "refuses to resolve at all when it cannot say who declares it" do
      # A reference the stamping walk missed must go RED, not nil — nil is
      # indistinguishable from a legitimate cross-domain target.
      orphan = Hecksagain::Bluebook::IR::Reference.new("Customer")

      expect { orphan.resolve }
        .to raise_error(Hecksagain::Bluebook::DSL::Malformed, /cannot say which aggregate declares it/)
    end

    it "keeps spelling the old reference string in the export, where Rust reads it" do
      account = banking.registry.bluebook("Banking").aggregate("Account")
      customer_id = account.attribute(:customer_id)

      expect(customer_id.type).to be_a(Hecksagain::Bluebook::IR::Reference)
      expect(customer_id.to_h[:type]).to eq("Reference<Customer>")
    end
  end

  describe "a command as a class" do
    def add_topping = pizzas.registry.bluebook("Pizzas").aggregate("Pizza").command("AddTopping")
    def create      = pizzas.registry.bluebook("Pizzas").aggregate("Pizza").command("CreatePizza")

    it "acts on the aggregate CLASS, not the name of one" do
      expect(add_topping).to be_a(Class)
      expect(add_topping.hecks_name).to eq("AddTopping")
      expect(add_topping.acts_on).to be(pizza)
    end

    it "acts on nothing when it is the command that creates" do
      expect(create.creates?).to be(true)
      expect(create.acts_on).to be_nil
    end

    it "still spells its name in the export, where Rust reads it" do
      expect(add_topping.to_h[:name]).to eq("AddTopping")
    end

    # WHY COMMANDS ARE NOT NESTED AS CONSTANTS, pinned so it is not "tidied up".
    #
    # A command and a value object may share a name inside one aggregate, and the
    # language does it six times ON PURPOSE: the command `Argument` is the verb
    # that appends to the `arguments` list whose element type is the value object
    # `Argument`, and `Plan` reads exactly that pairing to build the walk. So
    # `Meta::Command::Argument` cannot be both, and `hecks_fqn` is not unique
    # either — identity is (KIND, FQN). The judge's ids collide the same way and
    # get away with it because each category has its own repository.
    it "shares its name with a value object, which is why it is not a constant" do
      meta     = Hecksagain::Bluebook::MetaValidator.grammar_registry.bluebook("Meta")
      command  = meta.aggregate("Command")
      verb     = command.command("Argument")
      shape    = command.value_object("Argument")

      expect(verb).not_to be(shape)
      expect(verb.hecks_name).to eq(shape.hecks_name)
      # The same identity string for two different constructs — so the constant
      # tree cannot be the index for a kind-ambiguous name.
      expect(shape.hecks_fqn).to eq("Meta::Command.Argument")
      expect(command.ruby_class.const_get(:Argument)).to be(shape)
    end

    it "refuses to state an identity it was never given" do
      # Nothing in the corpus is in this state any more — the owner chain reaches
      # every command. But a construct built by hand, or one a future builder
      # forgets to stamp, must go RED rather than answer a bare name that looks
      # right.
      orphan = Hecksagain::Bluebook::IR::Command.declare(name: "Unstamped")

      expect(orphan.hecks_owner).to be_nil
      expect { orphan.hecks_fqn }
        .to raise_error(Hecksagain::Construct::Unowned, /cannot say what declares it/)
    end
  end

  describe "an entity as a class" do
    def account      = banking.registry.bluebook("Banking").aggregate("Account")
    def ledger_entry = account.entities.first

    it "closes the owner chain, so a piece's verb can say what it is" do
      # chapter -> aggregate -> entity -> command, which is the id the judge mints.
      expect(ledger_entry.hecks_fqn).to eq("Banking::Account.LedgerEntry")
      expect(ledger_entry.commands.map(&:hecks_fqn))
        .to eq(["Banking::Account.LedgerEntry.Amend", "Banking::Account.LedgerEntry.Reverse"])
    end

    it "has its verbs act on the PIECE, not on nothing" do
      # An element is addressed through its parent, so an entity's command never
      # self-references and `creates?` answers true for all of them. Reading
      # `acts_on` off that alone would claim `Amend` brings a ledger entry into
      # being — three of banking's commands, saying so with nothing to contradict
      # them.
      amend = ledger_entry.command("Amend")

      expect(amend.creates?).to be(true)
      expect(amend.acts_on).to be(ledger_entry)
    end

    it "stays structurally interchangeable with an aggregate" do
      # The runtime builds `Instance.new(aggregate: entity)` and `CommandRules`
      # takes either as `declaring`, so a piece answers the same questions a head
      # does.
      %i[hecks_name attributes attribute identified_by lifecycle commands queries].each do |message|
        expect(ledger_entry).to respond_to(message), "an entity must answer #{message} like an aggregate"
      end
    end

    it "keeps NOT answering value_object, which is how a piece is told from a head" do
      # `Value.for_attribute` sniffs for this method to decide whether it is
      # holding a head. An entity that grew one would silently start coercing its
      # fields as though it declared value objects.
      expect(ledger_entry).not_to respond_to(:value_object)
      expect(account).to respond_to(:value_object)
    end
  end
end
