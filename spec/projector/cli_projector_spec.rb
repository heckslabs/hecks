require "spec_helper"

# A BLUEBOOK, PROJECTED AS ITS OWN COMMAND-LINE SURFACE.
#
# Against banking and pizzas, not the chapter this was written beside — the
# same discipline the docs projector spec keeps, and it earned it twice here:
# banking is the domain that declares a command and a query of one name, and
# pizzas is the one whose value objects nest two deep.
RSpec.describe Hecksagain::Projector::CliProjector do
  def corpus
    registry = Hecksagain::Runtime::Registry.new
    Hecksagain.with_registry(registry) do
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

  def option(projection, verb, path)
    projection[:verbs].fetch(verb)[:arguments].find { |a| a[:path] == path }
  end

  it "is registered under :cli, reachable the way every projector is" do
    expect(Hecksagain::Projector).to be_registered(:cli)
  end

  it "names a subcommand after its aggregate and verb, and keeps the fully-qualified one" do
    expect(banking[:verbs]["account.freeze_account"][:verb]).to eq("Banking::Account.FreezeAccount")
    expect(banking[:verbs]["account.freeze_account"][:kind]).to eq(:command)
  end

  # THE COLLISION THAT DECIDED THE SHAPE. Banking declares a command
  # `Account.Open` and a query `Account.Open`; the language namespaces them and
  # a flat subcommand list cannot. Refusing would make banking uncallable, so
  # questions live under `ask` and the ambiguity cannot arise.
  it "keeps commands and questions in separate namespaces" do
    expect(banking[:verbs]).to have_key("account.open")
    expect(banking[:questions]).to have_key("account.open")
    expect(banking[:verbs]["account.open"][:verb]).to eq("Banking::Account.Open")
    expect(banking[:questions]["account.open"][:kind]).to eq(:query)
  end

  describe "the arguments" do
    # A CLI HANDS EVERYTHING OVER AS A STRING, so the declared type is the
    # only honest way to know what to send. Guessing from the value would send
    # the Integer 99 for a version string of "99".
    it "carries each field's declared type" do
      expect(option(banking, "account.open", "daily_limit.cents")[:type]).to eq("Integer")
      expect(option(banking, "account.open", "number.value")[:type]).to eq("String")
    end

    it "carries a closed set as the words it admits" do
      expect(option(pizzas, "order.create_pizza", "pizza.size.value")[:enum]).to contain_exactly("small", "large")
    end

    it "carries a declared pattern" do
      expect(option(banking, "customer.register", "email.address")[:pattern]).to be_a(String)
    end

    # NESTED TWO DEEP, WHICH A SINGLE LEVEL GOT WRONG. `Pizza` holds a `Price`,
    # so stopping at one level produced `pizza.price_cents` and sent the STRING
    # "1500" where `{ cents: 1500 }` belonged — and the runtime took it, per
    # qa/FINDINGS.md #2. Measured against a real store before it was fixed.
    it "recurses through a value object that holds another" do
      expect(option(pizzas, "order.create_pizza", "pizza.price_cents.cents")).not_to be_nil
      expect(option(pizzas, "order.create_pizza", "pizza.price_cents")).to be_nil
    end

    it "makes a cross-aggregate reference a plain id" do
      customer = option(banking, "account.open", "customer")
      expect(customer[:type]).to eq("String")
      expect(customer[:note]).to include("Customer")
    end

    # Receiver identity is projected beside, but kept separate from, the
    # command's declared facts.
    it "puts an aggregate receiver in to:, and only on a command that needs one" do
      expect(option(banking, "account.freeze_account", "to")).not_to be_nil
      expect(option(banking, "account.open", "to")).to be_nil
      expect(banking[:verbs]["account.freeze_account"][:receiver]).to eq(:aggregate)
    end

    it "projects aggregate and entity receiver identities separately for Visit.Annotate" do
      annotate = banking[:verbs].fetch("safe_deposit_box.visit.annotate")

      expect(annotate[:receiver]).to eq(:entity)
      expect(annotate[:arguments].first(2).map { |argument| argument[:path] })
        .to eq(["to.aggregate", "to.entity"])
      expect(annotate[:arguments].map { |argument| argument[:path] }).not_to include("date", "sequence")
    end
  end

  describe "the help" do
    it "lists verbs and questions separately, with what each is for" do
      expect(banking[:usage]).to include("verbs:")
      expect(banking[:usage]).to include("questions (nothing here changes anything):")
      expect(banking[:usage]).to include("freeze")
    end

    # THE SHORT SPELLING, WHERE IT CANNOT BE AMBIGUOUS. `pizzas create_pizza`
    # rather than `pizzas order.create_pizza`; the aggregate is worth typing
    # only when two of them declare the same word.
    it "shortens a verb no other aggregate declares, and keeps both spellings" do
      expect(pizzas[:verbs]["order.create_pizza"][:short]).to eq("create_pizza")
      expect(pizzas[:names][:command]["create_pizza"]).to eq("order.create_pizza")
      expect(pizzas[:names][:command]["order.create_pizza"]).to eq("order.create_pizza")
    end

    it "keeps the aggregate when two of them share a verb, rather than choosing" do
      shared = banking[:verbs].values.group_by { |spec| spec[:verb].split(".").last }
                              .find { |_, specs| specs.length > 1 }
      skip "banking declares no verb on two aggregates" unless shared

      expect(shared.last.map { |spec| spec[:short] }).to all(include("."))
    end

    it "lists the short spelling and says the long one still works" do
      expect(banking[:usage]).to include("a verb can always be spelled in full")
    end

    it "shows one verb's arguments and every way it refuses" do
      help = described_class.call(bluebook: registry.bluebook("Banking"),
                                  options:  { verb: "account.freeze_account" })[:usage]

      expect(help).to include("dispatches Banking::Account.FreezeAccount")
      expect(help).to include("issued by")
      expect(help).to match(/^\s+to\s+String; id of the Account to act on/)
      expect(help).to include("refused when:")
      expect(help).to include("status is not open")
    end

    # WITHOUT `ask:` A QUESTION'S HELP PRINTS THE COMMAND THAT SHARES ITS NAME.
    it "picks the namespace the caller asked about" do
      question = described_class.call(bluebook: registry.bluebook("Banking"),
                                      options:  { verb: "account.open", ask: true })[:usage]

      expect(question).to include("reads Banking::Account.Open")
      expect(question).to include("bin/run ask open")
    end
  end
end
