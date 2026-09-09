require "spec_helper"

# A BLUEBOOK, PROJECTED AS ITS OWN COMMAND-LINE SURFACE.
#
# Against banking and pizzas, not the chapter this was written beside — the
# same discipline the docs projector spec keeps, and it earned it twice here:
# banking is the domain that declares a command and a query of one name, and
# pizzas is the one whose value objects nest two deep.
RSpec.describe Hecks::Projector::CliProjector do
  def corpus
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      load_bluebook_files(InMemoryDomain::BANKING_BLUEBOOK_DIR)
      Kernel.load(InMemoryDomain::PIZZAS_BLUEBOOK)

      # PORTS ARE PROJECTED TOO (`CliProjector#port_spec`), and neither
      # banking nor pizzas' own `.bluebook` declares one — a port lives in
      # the hecksagon, the boundary file, same as `spec/
      # port_operation_interpreter_spec.rb` sets one up. Skipping this
      # left `aggregate.ports.each` in `#call` dead code as far as this
      # file's own corpus went, which is exactly how `port_spec` calling
      # a method (`receiver_options`) that is defined nowhere in the
      # codebase shipped and broke `bin/run` for every port-declaring
      # domain (pizzas' real `PaymentGateway` included) without this
      # spec file ever noticing.
      Kernel.load(File.join(InMemoryDomain::ROOT, "spec/fixtures/payments.bluebook"))
      Hecks.hecksagon("Payments") do
        uses_framework "Governance"
        Payments::Payment.persisted_by("Memory")

        Payments::Payment.port "PaymentGateway" do
          operation "Receive" do
            attribute :amount, Money
            emits "PaymentReceived"
          end
        end
      end
      Hecks.hecksagon("Governance") do
        Governance::RoleAssignment.persisted_by("Memory")
        Governance::RoleTransition.persisted_by("Memory")
      end
    end
    registry
  end

  # Read-only across every example in this file (never dispatched
  # against) — built once per file, not once per example, for speed.
  before(:context) { @registry = corpus }

  let(:registry) { @registry }
  let(:banking)  { described_class.call(bluebook: registry.bluebook("Banking")) }
  let(:pizzas)   { described_class.call(bluebook: registry.bluebook("Pizzas")) }
  let(:payments) { described_class.call(bluebook: registry.bluebook("Payments")) }

  def option(projection, verb, path)
    projection[:verbs].fetch(verb)[:arguments].find { |a| a[:path] == path }
  end

  it "is registered under :cli, reachable the way every projector is" do
    expect(Hecks::Projector).to be_registered(:cli)
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

    # A PORT IS A VERB TOO (`CliProjector#port_spec`) — it never had its own
    # receiver-argument code, it shares `command_spec`'s via
    # `receiver_options`, because a port operation always addresses an
    # aggregate record exactly the way a non-creating command does. This is
    # the one path through `#call` that only runs when a corpus actually
    # declares a port; without it here, `port_spec` calling a
    # never-defined method shipped undetected.
    it "projects a port operation as a verb, with the same aggregate receiver a command gets" do
      receive = payments[:verbs].fetch("payment.receive")

      expect(receive[:kind]).to eq(:command)
      expect(receive[:receiver]).to eq(:aggregate)
      expect(receive[:creates]).to be(false)
      expect(receive[:role_gated]).to be(false)
      expect(receive[:verb]).to eq("Payments::Payment.PaymentGateway.Receive")

      to = option(payments, "payment.receive", "to")
      expect(to[:required]).to be(true)
      expect(to[:note]).to include("Payment")
      expect(option(payments, "payment.receive", "amount.cents")).not_to be_nil
    end

    it "shows a port verb's help with its receiver argument and issuing side" do
      help = described_class.call(bluebook: registry.bluebook("Payments"),
                                  options:  { verb: "payment.receive" })[:usage]

      expect(help).to include("dispatches Payments::Payment.PaymentGateway.Receive")
      expect(help).to include("issued by PaymentGateway telling Payment")
      expect(help).to match(/^\s+to\s+String; id of the Payment to act on/)
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
