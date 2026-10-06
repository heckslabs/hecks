require "spec_helper"

CLI_PAYMENTS_HECKSAGON = proc do
  attaches "Governance"
  Payments::Payment.persisted_by("Memory")

  Payments::Payment.port "PaymentGateway" do
    operation "Receive" do
      attribute :amount, Money
      emits "PaymentReceived"
    end
  end
end

CLI_GOVERNANCE_HECKSAGON = proc do
  Governance::RoleAssignment.persisted_by("Memory")
  Governance::RoleTransition.persisted_by("Memory")
end

# The journaled-run bluebook `journaled_runs` builds, one proc per part of the Job aggregate.
RUNS_BLUEBOOK = proc do
  vision "A journaled run"
  aggregate "Job" do
    description "One job, from request to end."
    instance_exec(&RUNS_JOB_SHAPE)
    instance_exec(&RUNS_JOB_COMMAND)
    instance_exec(&RUNS_JOB_QUESTIONS)
  end
end

RUNS_JOB_SHAPE = proc do
  attribute :run, RunKey
  attribute :note, Note, optional: true
  identified_by :run
  value_object("RunKey") { attribute :value, String }
  value_object("Note") { attribute :value, String }
  value_object("Document") { attribute :text, String }
  lifecycle(:status, default: "requested") { transition "Fault" => "faulted", from: "requested" }
end

RUNS_JOB_COMMAND = proc do
  command "Fault" do
    role "System"
    goal "Record the failure"
    reference_to Job
    emits JobFaulted
  end
end

RUNS_JOB_QUESTIONS = proc do
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

# A bluebook, projected as its own command-line surface.
# Runs on banking (a command and query share a name) and pizzas (value objects nest two deep).
RSpec.describe Hecks::Projector::CliProjector do
  def corpus
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      load_adapters
      load_bluebook_files(InMemoryDomain::BANKING_BLUEBOOK_DIR)
      Kernel.load(InMemoryDomain::PIZZAS_BLUEBOOK)
      declare_payments_port
    end
    registry
  end

  def load_adapters
    [InMemoryDomain::PERSISTENCE_PORT, InMemoryDomain::EXTRACTION_PORT,
     InMemoryDomain::MEMORY_ADAPTER, InMemoryDomain::PRISM_ADAPTER].each { |file| Kernel.load(file) }
  end

  # Neither corpus bluebook declares a port (ports live in the hecksagon), so set one up here;
  # otherwise `CliProjector#port_spec` never runs.
  def declare_payments_port
    Kernel.load(File.join(InMemoryDomain::ROOT, "spec/fixtures/payments.bluebook"))
    Hecks.hecksagon("Payments", &CLI_PAYMENTS_HECKSAGON)
    Hecks.hecksagon("Governance", &CLI_GOVERNANCE_HECKSAGON)
  end

  # Read-only across every example (never dispatched against), so built once per file.
  before(:context) { @registry = corpus }

  let(:registry) { @registry }
  let(:banking)  { described_class.call(bluebook: registry.bluebook("Banking")) }
  let(:pizzas)   { described_class.call(bluebook: registry.bluebook("Pizzas")) }
  let(:payments) { described_class.call(bluebook: registry.bluebook("Payments")) }

  def command_help(bluebook, command, **options)
    described_class.call(bluebook: bluebook, options: { command: command, **options })[:usage]
  end

  def banking_bluebook = registry.bluebook("Banking")
  def payments_bluebook = registry.bluebook("Payments")

  def option(projection, command, path)
    projection[:commands].fetch(command)[:arguments].find { |a| a[:path] == path }
  end

  it "is registered under :cli, reachable the way every projector is" do
    expect(Hecks::Projector).to be_registered(:cli)
  end

  it "names a subcommand after its aggregate and command, and keeps the fully-qualified one", :aggregate_failures do
    expect(banking[:commands]["account.freeze_account"][:command]).to eq("Banking::Account.FreezeAccount")
    expect(banking[:commands]["account.freeze_account"][:kind]).to eq(:command)
  end

  # Banking declares a command and a query both named `Account.Open`, which a flat subcommand
  # list cannot hold; questions live under `ask`.
  it "keeps commands and questions in separate namespaces", :aggregate_failures do
    expect(banking[:commands]).to have_key("account.open")
    expect(banking[:questions]).to have_key("account.open")
    expect(banking[:commands]["account.open"][:command]).to eq("Banking::Account.Open")
    expect(banking[:questions]["account.open"][:kind]).to eq(:query)
  end

  describe "the arguments" do
    # A CLI hands over strings, so the declared type decides what to send; guessing from the
    # value would send the Integer 99 for a version string of "99".
    it "carries each field's declared type", :aggregate_failures do
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
    it "recurses through a value object that holds another", :aggregate_failures do
      expect(option(pizzas, "order.create_pizza", "pizza.price_cents.cents")).not_to be_nil
      expect(option(pizzas, "order.create_pizza", "pizza.price_cents")).to be_nil
    end

    it "makes a cross-aggregate reference a plain id", :aggregate_failures do
      customer = option(banking, "account.open", "customer")
      expect(customer[:type]).to eq("String")
      expect(customer[:note]).to include("Customer")
    end

    # Receiver identity is projected beside, but kept separate from, the
    # command's declared facts.
    it "puts an aggregate receiver in to:, and only on a command that needs one", :aggregate_failures do
      expect(option(banking, "account.freeze_account", "to")).not_to be_nil
      expect(option(banking, "account.open", "to")).to be_nil
      expect(banking[:commands]["account.freeze_account"][:receiver]).to eq(:aggregate)
    end

    it "projects aggregate and entity receiver identities separately for Visit.Annotate", :aggregate_failures do
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

      expect(receive.slice(:kind, :receiver, :creates, :role_gated, :command)).to eq(
        kind: :command, receiver: :aggregate, creates: false, role_gated: false,
        command: "Payments::Payment.PaymentGateway.Receive"
      )
    end

    it "gives a port command a required receiver argument and its operation's own arguments", :aggregate_failures do
      to = option(payments, "payment.receive", "to")

      expect(to).to include(required: true)
      expect(to[:note]).to include("Payment")
      expect(option(payments, "payment.receive", "amount.cents")).not_to be_nil
    end

    it "shows a port command's help with its receiver argument and issuing side", :aggregate_failures do
      help = command_help(payments_bluebook, "payment.receive")

      expect(help).to include("dispatches Payments::Payment.PaymentGateway.Receive")
      expect(help).to include("issued by PaymentGateway telling Payment")
      expect(help).to match(/^\s+to\s+String; id of the Payment to act on/)
    end
  end

  # One journaled run: a system-role command, the pair of questions every run has, and two real
  # questions on the same aggregate. Defined here rather than as a fixture file, which the
  # corpus accounting spec would ask to be accounted for.
  def journaled_runs
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) { Hecks.bluebook("Runs", &RUNS_BLUEBOOK) }
    registry
  end

  describe "the help" do
    it "lists commands and questions separately, with what each is for", :aggregate_failures do
      expect(banking[:usage]).to include("commands:")
      expect(banking[:usage]).to include("queries (nothing here changes anything):")
      expect(banking[:usage]).to include("freeze")
    end

    # A chapter with several aggregates reads as a table of contents: a heading per aggregate, its
    # commands beneath it, instead of one flat list in declaration order.
    it "groups the commands and questions under a heading per aggregate", :aggregate_failures do
      usage = banking[:usage]

      expect(usage).to match(/^  customer:\n(?:    [A-Z][^\n]*\n)?    register!\s+Take on a new customer/)
      expect(usage).to match(/^  account:\n(?:    [A-Z][^\n]*\n)?    open!\s+/)
      expect(banking[:commands]["account.freeze_account"][:group]).to eq("Account")
    end

    # The pair every journaled run has (how one run ended, which ones failed) is read through
    # `--wait`, not asked for by name. Only a query that reads the run's own records back by its
    # identity or its status counts; a query that filters on anything else, or returns a document,
    # is a real question even on the same aggregate.
    describe "a journaled run" do
      let(:runs) { described_class.call(bluebook: journaled_runs.bluebook("Runs")) }

      it "sets its own outcome and fault questions apart" do
        internal = runs[:questions].values.select { |spec| spec[:internal] }.map { |spec| spec[:short] }

        expect(internal).to contain_exactly("job.job_outcome", "job.job_faulted")
      end

      it "keeps real questions listed, and not the run's own", :aggregate_failures do
        expect(runs[:usage]).to match(/^\s+job\.jobs_by_note\s+/)
        expect(runs[:usage]).to match(/^\s+job\.job_digest\s+/)
        expect(runs[:usage]).not_to match(/^\s+job\.job_outcome\s{2,}How one job ended/)
      end
    end

    it "titles a heading with its aggregate's name, the prefix of every call under it", :aggregate_failures do
      expect(described_class.send(:heading, "TestSuiteRun")).to eq("test_suite_run:")
      expect(described_class.send(:heading, "Operation")).to eq("operation:")
    end

    it "leaves the aggregate prefix off the lines under its heading, and keeps it without one", :aggregate_failures do
      expect(banking[:usage]).not_to match(/^\s+customer\.register!/)
      expect(banking[:usage]).to match(/^  customer:\n(?:    [A-Z][^\n]*\n)?    register!/)
      expect(banking[:usage]).to match(/^    open!\s/)
      expect(described_class.send(:entry_name, { kind: :command, short: "pizza.make", group: "Pizza" }, false))
        .to eq("pizza.make!")
    end

    it "lists a command the chapter gave a short name by its real name, and says the short name", :aggregate_failures do
      spec = { kind: :command, short: "mcp", short_was: "door.serve_mcp", group: "Door" }

      expect(described_class.send(:entry_name, spec, true)).to eq("serve_mcp!")
      expect(described_class.send(:alias_note, spec)).to eq(" (also: mcp!)")
      expect(described_class.send(:alias_note, { kind: :command, short: "init", short_was: "door.init" })).to eq("")
    end

    # What a run records about itself (system-role commands, port operations) is never typed by a
    # person, so the help names it on a line of its own instead of spending a described line each.
    describe "bookkeeping commands" do
      let(:port_verb) { payments[:commands].values.find { |spec| spec[:command].include?("PaymentGateway") } }

      def all = described_class.call(bluebook: payments_bluebook, options: { all: true })[:usage]

      it "are marked internal" do
        expect(port_verb[:internal]).to be(true)
      end

      it "stay out of the usage, which says how many were left out", :aggregate_failures do
        expect(payments[:usage]).not_to include("internal — what a run records about itself")
        expect(payments[:usage]).not_to include(port_verb[:short])
        expect(payments[:usage]).to match(/--all\s+also list the \d+ internal/)
      end

      it "are listed when all is asked for", :aggregate_failures do
        expect(all).to include("internal — what a run records about itself")
        expect(all).to include(port_verb[:short])
      end
    end

    # A command is always named with its aggregate: no short spelling is minted.
    it "names every command with its aggregate, and mints no bare spelling", :aggregate_failures do
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

    # The audience decides what the help lists; every command still runs and answers `--help`.
    describe "for an audience" do
      let(:hidden) do
        described_class.call(bluebook: registry.bluebook("Banking"), options: { hide: %w[Account], program: "hecks" })
      end

      it "leaves the hidden aggregates out of the lists and says how many, and how to list them", :aggregate_failures do
        expect(hidden[:usage]).not_to match(/^  account:$/)
        expect(hidden[:usage]).to match(/^  customer:$/)
        expect(hidden[:usage]).to match(/hecks --maintainer\s+also list the \d+ commands and queries for working on hecks itself/)
      end

      it "keeps the hidden commands in the surface the runner dispatches from" do
        expect(hidden[:commands].keys).to eq(banking[:commands].keys)
      end

      it "makes no mention of a maintainer when nothing was hidden" do
        expect(banking[:usage]).not_to include("--maintainer")
      end

      it "points at the chapters it is given, one line each, cut to a line", :aggregate_failures do
        chapters = [["deploy", "Ship it."], ["tenancy", "word " * 40]]
        usage = described_class.call(bluebook: banking_bluebook, options: { program: "hecks", chapters: chapters })[:usage]

        expect(usage).to include("chapters (`hecks <chapter>` lists a chapter's own commands and queries):")
        expect(usage).to match(/^  deploy   Ship it\.$/)
        expect(usage).to match(/^  tenancy  word word.*word…$/)
      end
    end

    it "shows one command's arguments and every way it refuses", :aggregate_failures do
      help = command_help(banking_bluebook, "account.freeze_account")

      expect(help).to include("dispatches Banking::Account.FreezeAccount", "issued by", "refused when:", "status is not open")
      expect(help).to match(/^\s+to\s+String; id of the Account to act on/)
    end

    describe "a given" do
      let(:lines) { command_help(banking_bluebook, "account.freeze_account").lines.map(&:chomp) }

      it "is worded as what must hold, so the command is refused unless it does" do
        expect(lines[lines.index("refused unless:") + 1]).to eq("  customer is not closed")
      end

      it "is not listed among what refuses the command when it holds" do
        refused_when = lines[(lines.index("refused when:") + 1)..].take_while { |l| l.start_with?("  ") }

        expect(refused_when).not_to include("  customer is not closed")
      end
    end

    # Without `ask:` a question's help prints the command that shares its name.
    it "picks the namespace the caller asked about", :aggregate_failures do
      question = command_help(banking_bluebook, "account.open", ask: true)

      expect(question).to include("reads Banking::Account.Open")
      expect(question).to include("hecks run query account.open")
    end
  end
end
