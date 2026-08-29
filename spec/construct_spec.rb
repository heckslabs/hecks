require "spec_helper"
require "stringio"

# A CONSTRUCT IS A RECORD WITH AN OWNER CHAIN, AND WHAT POINTS AT ONE IS AN EDGE.
#
# The chain is IR objects end to end : the chapter (Bluebook) owns its
# aggregates, an aggregate owns its commands, value objects, entities and asks,
# and `hecks_fqn` is COMPUTED by walking owners — the same spelling
# `MetaValidator::Judge#identify` mints, so a construct and the language's
# record OF that construct need no translation between them.
#
# `reference_to Customer` is an `Reference`, which RESOLVES to the target's
# Aggregate through the chapter's own declared heads — scoped by
# construction, lazy on purpose (the target may be declared lower in the file).
#
# Three aggregates in banking each declare their own `Narrative`; the owner
# chain is what keeps them three distinguishable facts.
RSpec.describe "a construct's identity" do
  CONSTRUCT_PIZZAS  = InMemoryDomain::PIZZAS_BLUEBOOK
  CONSTRUCT_BANKING = InMemoryDomain::BANKING_BLUEBOOK_DIR

  # The house pattern — load into a fresh registry against the Memory adapter, so
  # no example touches a data directory. `Hecks.boot` on a real example domain
  # would bind Heki and write to disk.
  def boot(bluebook)
    registry = Hecks::Runtime::Registry.new

    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      load_bluebook_files(bluebook)
      Hecks::Runtime::Loader.bind_runtime(
        Hecks::Runtime::Dispatcher.new(registry)
      )
    end
  end

  # Booted ONCE per file, not per example — every `it` below only reads the
  # IR back out (see the file's header: the one real `.dispatch` in this
  # file always raises `NotFound` before anything persists), so nothing an
  # earlier example does can leak into a later one. `before(:context)`'s
  # ivars are copied onto every example instance, so `pizzas`/`banking`
  # still read as a plain per-example accessor below.
  before(:context) do
    @pizzas  = boot(CONSTRUCT_PIZZAS)
    @banking = boot(CONSTRUCT_BANKING)
  end

  attr_reader :pizzas
  attr_reader :banking

  def aggregate_ir(runtime, domain, name)
    runtime.registry.bluebook(domain).aggregate(name)
  end

  def pizza = aggregate_ir(pizzas, "Pizzas", "Order")

  describe "the name it is declared by" do
    it "spells an aggregate one way, from the owner chain alone" do
      expect(pizza.hecks_name).to eq("Order")
      expect(pizza.hecks_fqn).to eq("Pizzas::Order")
    end

    it "spells a value object the way the meta-domain already ids one" do
      # `MetaValidator::Judge#identify` mints "#{parent_id}.#{name}" for every
      # category below an aggregate. Same string, reached by walking the IR's
      # own owners — so a construct and the language's record OF that construct
      # need no translation between them.
      expect(pizza.value_object("Price").hecks_fqn).to eq("Pizzas::Order.Price")
    end

    it "reaches a value object through the head that declares it" do
      price = pizza.value_object("Price")

      expect(price.hecks_name).to eq("Price")
      expect(price.attributes.map(&:name)).to eq([:cents])
    end

    it "keeps three same-named value objects distinguishable" do
      shapes = %w[Account ATMCard Transfer].map do |owner|
        aggregate_ir(banking, "Banking", owner).value_object("Narrative")
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
    it "resolves every reference in banking to a head in its own chapter" do
      found = references_in(banking, "Banking")

      # NOW 22, not 21 — Wave 7's reference-decluttering targeted every
      # creating command that redundantly spelled `reference_to <target>`
      # itself, but `SafeDepositBox.Rent` had a DIFFERENT bug the same
      # sweep didn't catch: it redeclared `attribute :customer,
      # CustomerNumber` — Customer's own identity VALUE OBJECT, not a
      # reference — which SHADOWED the aggregate's own `belongs_to
      # Customer` (a real `Reference`) with an incompatible type. Not a
      # redundant declaration, a WRONG one: `references_in` counts the
      # COMPILED shape, and `Rent`'s own `customer` attribute never
      # compiled to a reference at all, so it was silently absent from
      # this count — harmless until a `given("customer is active")` guard
      # (issue #278) tried to dereference it and was refused for every
      # customer, active or not. Fixed the same way Wave 7 fixed the
      # other nine: removed the redundant/wrong attribute redeclaration,
      # letting `sets :customer` import the aggregate's own Reference-
      # typed attribute instead of shadowing it. `21 + 1 = 22`.
      expect(found.size).to eq(22)
      found.each do |owner, attribute|
        resolved = attribute.type.resolve

        expect(resolved).to be_a(Hecks::Bluebook::Aggregate),
                            "#{owner}##{attribute.name} resolved to #{resolved.inspect}"
        expect(resolved.hecks_name).to eq(attribute.type.target_name)
        expect(resolved.hecks_owner.hecks_name).to eq("Banking")
      end
    end

    it "still refuses a reference that points at nothing" do
      expect do
        # `number:` was written TWICE — the first a copy of the customer id — and
        # Ruby warned on every run while silently keeping the second. What this
        # test is about is the CUSTOMER pointing at nothing, not the number.
        banking.dispatch("Banking::Account.Open", customer:    "nobody-registered-this",
                                                  number:      { value: "ACC-1" },
                                                  kind:        { name: "current" },
                                                  daily_limit: { cents: 100 })
      end.to raise_error(Hecks::Runtime::NotFound, /no Customer with/)
    end

    it "refuses to resolve at all when it cannot say who declares it" do
      # A reference the stamping walk missed must go RED, not nil — nil is
      # indistinguishable from a legitimate cross-domain target.
      orphan = Hecks::Bluebook::Reference.new("Customer")

      expect { orphan.resolve }
        .to raise_error(Hecks::Bluebook::DSL::Malformed, /cannot say which aggregate declares it/)
    end

    it "keeps spelling the old reference string in the export, whose spelling is contract" do
      account = banking.registry.bluebook("Banking").aggregate("Account")
      customer = account.attribute(:customer)

      expect(customer.type).to be_a(Hecks::Bluebook::Reference)
      expect(customer.to_h[:type]).to eq("Reference<Customer>")
    end
  end

  describe "a command as a class" do
    def add_topping = pizzas.registry.bluebook("Pizzas").aggregate("Order").command("AddTopping")
    def create      = pizzas.registry.bluebook("Pizzas").aggregate("Order").command("CreatePizza")

    it "acts on the aggregate itself, not the name of one" do
      expect(add_topping).to be_a(Class)
      expect(add_topping.hecks_name).to eq("AddTopping")
      expect(add_topping.acts_on).to be(pizzas.registry.bluebook("Pizzas").aggregate("Order"))
    end

    it "acts on nothing when it is the command that creates" do
      expect(create.creates?).to be(true)
      expect(create.acts_on).to be_nil
    end

    it "still spells its name in the export, whose spelling is contract" do
      expect(add_topping.to_h[:name]).to eq("AddTopping")
    end

    # WHY COMMANDS ARE NOT NESTED AS CONSTANTS, pinned so it is not "tidied up".
    #
    # A command and a value object may share a name inside one aggregate, and the
    # language does it six times ON PURPOSE: the command `Argument` is the verb
    # that appends to the `arguments` list whose element type is the value object
    # `Argument`, and `Plan` reads exactly that pairing to build the walk. So
    # `Bluebook::Command::Argument` cannot be both, and `hecks_fqn` is not unique
    # either — identity is (KIND, FQN). The judge's ids collide the same way and
    # get away with it because each category has its own repository.
    it "shares its name with a value object, which is why it is not a constant" do
      meta     = Hecks::Bluebook::MetaValidator.grammar_registry.bluebook("Bluebook")
      command  = meta.aggregate("Command")
      verb     = command.command("Argument")
      shape    = command.value_object("Argument")

      expect(verb).not_to be(shape)
      expect(verb.hecks_name).to eq(shape.hecks_name)
      # The same identity string for two different constructs — so the constant
      # tree cannot be the index for a kind-ambiguous name.
      expect(shape.hecks_fqn).to eq("Bluebook::Command.Argument")
      expect(command.value_object("Argument")).to be(shape)
    end

    it "refuses to state an identity it was never given" do
      # Nothing in the corpus is in this state any more — the owner chain reaches
      # every command. But a construct built by hand, or one a future builder
      # forgets to stamp, must go RED rather than answer a bare name that looks
      # right.
      orphan = Hecks::Bluebook::Command.declare(name: "Unstamped")

      expect(orphan.hecks_owner).to be_nil
      expect { orphan.hecks_fqn }
        .to raise_error(Hecks::Construct::Unowned, /cannot say what declares it/)
    end
  end

  describe "the chapter, and why one table survives" do
    it "is a root, so it is the one construct with no owner to name" do
      chapter = banking.registry.bluebook("Banking")

      expect(chapter.hecks_root?).to be(true)
      expect(chapter.hecks_fqn).to eq("Banking")
    end

    it "answers hecks_name from every construct, crossed over or not" do
      # The universal question. If one of these stops answering, the consumers that
      # cannot tell a class from an IR object — `Instance.new(aggregate: entity)`,
      # `CommandRules#admissible_transition(declaring, …)` — start reading nil.
      bank    = banking.registry.bluebook("Banking")
      account = bank.aggregate("Account")

      [bank, account, account.command("Open"), account.query("Open"),
       account.entities.first, account.entities.first.commands.first,
       account.value_objects.first, bank.read_models.first,
       bank.policies.first, bank.process_managers.first].each do |construct|
        expect(construct.hecks_name).to be_a(String), "#{construct.inspect} answers no hecks_name"
        expect(construct.hecks_name).not_to be_empty
      end
    end

    # WHY `Registry` KEEPS A CHAPTER TABLE, pinned so it is not "optimised" away.
    #
    # The DOOR installs at TOP LEVEL, where the names are not ours — so
    # `Namespace.install` warns and keeps the existing constant, and the
    # chapter's door is never reachable that way. The registry's own table is
    # the index the runtime trusts ; a domain is entered by name exactly once,
    # and everything below it is traversal through the IR.
    it "cannot be indexed by Ruby's constants, because top-level names are not ours" do
      registry = Hecks::Runtime::Registry.new

      expect do
        Hecks.with_registry(registry) do
          Kernel.load(InMemoryDomain::EXTRACTION_PORT)
          Kernel.load(InMemoryDomain::PRISM_ADAPTER)
          Hecks.bluebook("Set") do
            vision "a domain whose name Ruby already uses"
            supporting
            aggregate("Thing") do
              identified_by :id
              description "a thing"
              attribute :label, Label
              value_object("Label") { attribute :value, String }
            end
          end
        end
        # Installation happens at BIND, not at load — the door is a per-boot
        # projection, and this is the moment it meets Ruby's own `Set`.
        Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
      end.to output(/Set is already defined — leaving it alone/).to_stderr

      expect(registry.bluebook("Set").hecks_fqn).to eq("Set")
      expect(Object.const_get(:Set)).not_to be(registry.bluebook("Set"))
    end
  end

  describe "an ask, which stays an instance" do
    def bank = banking.registry.bluebook("Banking")

    it "hangs a query off whatever declares it" do
      account = bank.aggregate("Account")

      expect(account.queries.map(&:hecks_fqn))
        .to include("Banking::Account.Overdrawn")
      expect(account.entities.first.queries.map(&:hecks_fqn))
        .to eq(["Banking::Account.LedgerEntry.Reversed"])
    end

    it "hangs a read model off the CHAPTER, since no one head declares it" do
      # A read model gathers heads from several aggregates. Hanging it off one of
      # them would name the wrong owner.
      expect(bank.read_models.map(&:hecks_fqn)).to eq(
        ["Banking.CustomerPortfolio", "Banking.ComplianceDashboard", "Banking.DisputedPaymentCount",
         "Banking.DisputedPaymentMedian", "Banking.AccountsByKind"]
      )
    end

    it "keeps the name it always had, because only a class had a rival answer" do
      # `Class#name` is what forced a second word for a construct's own name. An
      # instance has no such conflict, so a query answers both, identically.
      ask = bank.aggregate("Account").queries.first

      expect(ask.name).to eq(ask.hecks_name)
    end

    it "keeps every option its specification superclass carries" do
      # This is why an ask is NOT hoisted onto a metaclass: its whole body is
      # inherited instance methods that the runtime and the SQLite adapter read.
      ask = bank.aggregate("Account").query("Overdrawn")

      %i[wheres order_by limit offset cursor
         authorization null_semantics inspection].each do |option|
        expect(ask).to respond_to(option), "an ask must still answer #{option}"
      end
    end

    it "collides with a command of the same name, in a real domain this time" do
      # The kind-ambiguity finding is not a quirk of the language describing
      # itself: banking declares BOTH a command and a query called Open on
      # Account, so "Banking::Account.Open" names two constructs here too.
      account = bank.aggregate("Account")

      expect(account.command("Open").hecks_fqn).to eq("Banking::Account.Open")
      expect(account.query("Open").hecks_fqn).to eq("Banking::Account.Open")
      expect(account.command("Open")).not_to be(account.query("Open"))
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
