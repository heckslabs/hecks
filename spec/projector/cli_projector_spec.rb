require "spec_helper"

# A bluebook, projected as its own command-line surface.
# Runs on banking (a command and query share a name) and pizzas (value objects nest two deep).
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

      # Neither corpus bluebook declares a port (ports live in the hecksagon), so set one up here;
      # otherwise `CliProjector#port_spec` never runs.
      Kernel.load(File.join(InMemoryDomain::ROOT, "spec/fixtures/payments.bluebook"))
      Hecks.hecksagon("Payments") do
        attaches "Governance"
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

  # Read-only across every example (never dispatched against), so built once per file.
  before(:context) { @registry = corpus }

  let(:registry) { @registry }
  let(:banking)  { described_class.call(bluebook: registry.bluebook("Banking")) }
  let(:pizzas)   { described_class.call(bluebook: registry.bluebook("Pizzas")) }
  let(:payments) { described_class.call(bluebook: registry.bluebook("Payments")) }

  def option(projection, command, path)
    projection[:commands].fetch(command)[:arguments].find { |a| a[:path] == path }
  end

  it "is registered under :cli, reachable the way every projector is" do
    expect(Hecks::Projector).to be_registered(:cli)
  end

  it "names a subcommand after its aggregate and command, and keeps the fully-qualified one" do
    expect(banking[:commands]["account.freeze_account"][:command]).to eq("Banking::Account.FreezeAccount")
    expect(banking[:commands]["account.freeze_account"][:kind]).to eq(:command)
  end

  # Banking declares a command and a query both named `Account.Open`, which a flat subcommand
  # list cannot hold; questions live under `ask`.
  it "keeps commands and questions in separate namespaces" do
    expect(banking[:commands]).to have_key("account.open")
    expect(banking[:questions]).to have_key("account.open")
    expect(banking[:commands]["account.open"][:command]).to eq("Banking::Account.Open")
    expect(banking[:questions]["account.open"][:kind]).to eq(:query)
  end

  describe "the arguments" do
    # A CLI hands over strings, so the declared type decides what to send; guessing from the
    # value would send the Integer 99 for a version string of "99".
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

    # Nested two deep: `Pizza` holds a `Price`, and stopping at one level sent "1500"
    # where `{ cents: 1500 }` belongs.
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
      expect(banking[:commands]["account.freeze_account"][:receiver]).to eq(:aggregate)
    end

    it "projects aggregate and entity receiver identities separately for Visit.Annotate" do
      annotate = banking[:commands].fetch("safe_deposit_box.visit.annotate")

      expect(annotate[:receiver]).to eq(:entity)
      expect(annotate[:arguments].first(2).map { |argument| argument[:path] })
        .to eq(["to.aggregate", "to.entity"])
      expect(annotate[:arguments].map { |argument| argument[:path] }).not_to include("date", "sequence")
    end

    # A port is a command too; it shares `command_spec`'s `receiver_options`. This is the only path
    # through `#call` that runs when a corpus declares a port.
    it "projects a port operation as a command, with the same aggregate receiver a command gets" do
      receive = payments[:commands].fetch("payment.receive")

      expect(receive[:kind]).to eq(:command)
      expect(receive[:receiver]).to eq(:aggregate)
      expect(receive[:creates]).to be(false)
      expect(receive[:role_gated]).to be(false)
      expect(receive[:command]).to eq("Payments::Payment.PaymentGateway.Receive")

      to = option(payments, "payment.receive", "to")
      expect(to[:required]).to be(true)
      expect(to[:note]).to include("Payment")
      expect(option(payments, "payment.receive", "amount.cents")).not_to be_nil
    end

    it "shows a port command's help with its receiver argument and issuing side" do
      help = described_class.call(bluebook: registry.bluebook("Payments"),
                                  options:  { command: "payment.receive" })[:usage]

      expect(help).to include("dispatches Payments::Payment.PaymentGateway.Receive")
      expect(help).to include("issued by PaymentGateway telling Payment")
      expect(help).to match(/^\s+to\s+String; id of the Payment to act on/)
    end
  end

  # One journaled run: a system-role command, the pair of questions every run has, and two real
  # questions on the same aggregate. Defined here rather than as a fixture file, which the
  # corpus accounting spec would ask to be accounted for.
  def journaled_runs # rubocop:disable Metrics/MethodLength
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      Hecks.bluebook "Runs" do
        vision "A journaled run"
        aggregate "Job" do
          description "One job, from request to end."
          attribute :run, RunKey
          attribute :note, Note, optional: true
          identified_by :run
          value_object("RunKey") { attribute :value, String }
          value_object("Note") { attribute :value, String }
          value_object("Document") { attribute :text, String }
          lifecycle(:status, default: "requested") { transition "Fault" => "faulted", from: "requested" }
          command "Fault" do
            role "System"
            goal "Record the failure"
            reference_to Job
            emits JobFaulted
          end
          query "JobOutcome" do
            description "How one job ended."
            attribute :run, RunKey
            where(run: :run)
          end
          query "JobFaulted" do
            description "Every job that failed."
            where(status: "faulted")
          end
          query "JobsByNote" do
            description "Jobs by note."
            attribute :note, Note
            where(note: :note)
          end
          query "JobDigest" do
            description "A digest."
            returns Document
          end
        end
      end
    end
    registry
  end

  describe "the help" do
    it "lists commands and questions separately, with what each is for" do
      expect(banking[:usage]).to include("commands:")
      expect(banking[:usage]).to include("queries (nothing here changes anything):")
      expect(banking[:usage]).to include("freeze")
    end

    # A chapter with several aggregates reads as a table of contents: a heading per aggregate, its
    # commands beneath it, instead of one flat list in declaration order.
    it "groups the commands and questions under a heading per aggregate" do
      usage = banking[:usage]

      expect(usage).to match(/^  Customer:\n    customer\.register!\s+Take on a new customer/)
      expect(usage).to match(/^  Account:\n    account\.open!\s+/)
      expect(banking[:commands]["account.freeze_account"][:group]).to eq("Account")
    end

    # The pair every journaled run has (how one run ended, which ones failed) is read through
    # `--wait`, not asked for by name. Only a query that reads the run's own records back by its
    # identity or its status counts; a query that filters on anything else, or returns a document,
    # is a real question even on the same aggregate.
    it "sets a run's own outcome and fault questions apart, and keeps real questions listed" do
      runs = described_class.call(bluebook: journaled_runs.bluebook("Runs"))
      internal = runs[:questions].values.select { |spec| spec[:internal] }.map { |spec| spec[:short] }

      expect(internal).to contain_exactly("job.job_outcome", "job.job_faulted")
      expect(runs[:usage]).to match(/^\s+job\.jobs_by_note\s+/)
      expect(runs[:usage]).to match(/^\s+job\.job_digest\s+/)
      expect(runs[:usage]).not_to match(/^\s+job\.job_outcome\s{2,}How one job ended/)
    end

    it "titles a heading after its aggregate, without a Run suffix" do
      heading = described_class.send(:heading, "TestSuiteRun")

      expect(heading).to eq("Test suite:")
      expect(described_class.send(:heading, "Operation")).to eq("Operation:")
    end

    # What a run records about itself (system-role commands, port operations) is never typed by a
    # person, so the help names it on a line of its own instead of spending a described line each.
    it "sets bookkeeping commands apart as names only" do
      usage = payments[:usage]
      port_verb = payments[:commands].values.find { |spec| spec[:command].include?("PaymentGateway") }

      expect(port_verb[:internal]).to be(true)
      expect(usage).to include("internal — what a run records about itself")
      expect(usage).not_to include("#{port_verb[:short].ljust(5)}  #{port_verb[:summary]}")
      expect(usage).to include(port_verb[:short])
    end

    # A command is always named with its aggregate: no short spelling is minted.
    it "names every command with its aggregate, and mints no bare spelling" do
      expect(pizzas[:commands]["order.create_pizza"][:short]).to eq("order.create_pizza")
      expect(pizzas[:names][:command]["order.create_pizza"]).to eq("order.create_pizza")
      expect(pizzas[:names][:command]).not_to have_key("create_pizza")
    end

    it "shows every command by its dotted name, whether or not another aggregate shares the command word" do
      expect(banking[:commands].values.map { |spec| spec[:short] }).to all(include("."))
    end

    it "says a command is called with its aggregate" do
      expect(banking[:usage]).to include("a command is called with its aggregate — customer.register!")
    end

    it "shows one command's arguments and every way it refuses" do
      help = described_class.call(bluebook: registry.bluebook("Banking"),
                                  options:  { command: "account.freeze_account" })[:usage]

      expect(help).to include("dispatches Banking::Account.FreezeAccount")
      expect(help).to include("issued by")
      expect(help).to match(/^\s+to\s+String; id of the Account to act on/)
      expect(help).to include("refused when:")
      expect(help).to include("status is not open")
    end

    it "words a given as what must hold, so the command is refused unless it does" do
      help  = described_class.call(bluebook: registry.bluebook("Banking"),
                                   options:  { command: "account.freeze_account" })[:usage]
      lines = help.lines.map(&:chomp)

      unless_at = lines.index("refused unless:")
      expect(unless_at).not_to be_nil
      expect(lines[unless_at + 1]).to eq("  customer is not closed")
      expect(lines[(lines.index("refused when:") + 1)..].take_while { |l| l.start_with?("  ") })
        .not_to include("  customer is not closed")
    end

    # Without `ask:` a question's help prints the command that shares its name.
    it "picks the namespace the caller asked about" do
      question = described_class.call(bluebook: registry.bluebook("Banking"),
                                      options:  { command: "account.open", ask: true })[:usage]

      expect(question).to include("reads Banking::Account.Open")
      expect(question).to include("hecks run query account.open")
    end
  end
end
