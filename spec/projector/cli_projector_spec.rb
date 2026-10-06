require "spec_helper"

# A bluebook, projected as its own command-line surface.
# Runs on banking (a command and query share a name) and pizzas (value objects nest two deep).
RSpec.describe Hecks::Projector::CliProjector do
  def load_in_memory_ports
    [InMemoryDomain::PERSISTENCE_PORT, InMemoryDomain::EXTRACTION_PORT,
     InMemoryDomain::MEMORY_ADAPTER, InMemoryDomain::PRISM_ADAPTER].each { |path| Kernel.load(path) }
  end

  # Neither corpus bluebook declares a port (ports live in the hecksagon), so set one up here;
  # otherwise `CliProjector#port_spec` never runs.
  def declare_payments_port
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
  end

  def declare_governance_persistence
    Hecks.hecksagon("Governance") do
      Governance::RoleAssignment.persisted_by("Memory")
      Governance::RoleTransition.persisted_by("Memory")
    end
  end

  def corpus
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      load_in_memory_ports
      load_bluebook_files(InMemoryDomain::BANKING_BLUEBOOK_DIR)
      Kernel.load(InMemoryDomain::PIZZAS_BLUEBOOK)
      Kernel.load(File.join(InMemoryDomain::ROOT, "spec/fixtures/payments.bluebook"))
      declare_payments_port
      declare_governance_persistence
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

  def usage_for(domain, **options) = described_class.call(bluebook: registry.bluebook(domain), options: options)[:usage]

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

    def receive_command = payments[:commands].fetch("payment.receive")

    # A port is a command too; it shares `command_spec`'s `receiver_options`. This is the only path
    # through `#call` that runs when a corpus declares a port.
    it "projects a port operation as a command", :aggregate_failures do
      expect(receive_command[:kind]).to eq(:command)
      expect(receive_command[:command]).to eq("Payments::Payment.PaymentGateway.Receive")
    end

    it "gives a port operation the same aggregate receiver a command gets", :aggregate_failures do
      expect(receive_command[:receiver]).to eq(:aggregate)
      expect(receive_command[:creates]).to be(false)
      expect(receive_command[:role_gated]).to be(false)
    end

    it "asks for the receiver's id and the operation's own arguments", :aggregate_failures do
      to = option(payments, "payment.receive", "to")

      expect(to[:required]).to be(true)
      expect(to[:note]).to include("Payment")
      expect(option(payments, "payment.receive", "amount.cents")).not_to be_nil
    end

    it "shows a port command's help with its receiver argument and issuing side", :aggregate_failures do
      help = usage_for("Payments", command: "payment.receive")

      expect(help).to include("dispatches Payments::Payment.PaymentGateway.Receive")
      expect(help).to include("issued by PaymentGateway telling Payment")
      expect(help).to match(/^\s+to\s+String; id of the Payment to act on/)
    end
  end

  # One journaled run: a system-role command, the pair of questions every run has, and two real
  # questions on the same aggregate. Defined here rather than as a fixture file, which the
  # corpus accounting spec would ask to be accounted for. Each piece is a block the aggregate
  # builder evaluates in order.
  def journaled_runs
    pieces = [job_shape, job_fault_command, job_outcome_query, job_faulted_query, job_by_note_query, job_digest_query]
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      Hecks.bluebook "Runs" do
        vision "A journaled run"
        aggregate("Job") { pieces.each { |piece| instance_exec(&piece) } }
      end
    end
    registry
  end

  def job_shape
    proc do
      description "One job, from request to end."
      attribute :run, RunKey
      attribute :note, Note, optional: true
      identified_by :run
      value_object("RunKey") { attribute :value, String }
      value_object("Note") { attribute :value, String }
      value_object("Document") { attribute :text, String }
      lifecycle(:status, default: "requested") { transition "Fault" => "faulted", from: "requested" }
    end
  end

  def job_fault_command
    proc do
      command "Fault" do
        role "System"
        goal "Record the failure"
        reference_to Job
        emits JobFaulted
      end
    end
  end

  def job_outcome_query
    proc do
      query "JobOutcome" do
        description "How one job ended."
        attribute :run, RunKey
        where(run: :run)
      end
    end
  end

  def job_faulted_query
    proc do
      query "JobFaulted" do
        description "Every job that failed."
        where(status: "faulted")
      end
    end
  end

  def job_by_note_query
    proc do
      query "JobsByNote" do
        description "Jobs by note."
        attribute :note, Note
        where(note: :note)
      end
    end
  end

  def job_digest_query
    proc do
      query "JobDigest" do
        description "A digest."
        returns Document
      end
    end
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
    def runs_projection = described_class.call(bluebook: journaled_runs.bluebook("Runs"))

    it "sets a run's own outcome and fault questions apart" do
      internal = runs_projection[:questions].values.select { |spec| spec[:internal] }.map { |spec| spec[:short] }

      expect(internal).to contain_exactly("job.job_outcome", "job.job_faulted")
    end

    it "keeps real questions listed", :aggregate_failures do
      usage = runs_projection[:usage]

      expect(usage).to match(/^\s+job\.jobs_by_note\s+/)
      expect(usage).to match(/^\s+job\.job_digest\s+/)
      expect(usage).not_to match(/^\s+job\.job_outcome\s{2,}How one job ended/)
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
    def port_verb = payments[:commands].values.find { |spec| spec[:command].include?("PaymentGateway") }

    it "marks a port operation internal" do
      expect(port_verb[:internal]).to be(true)
    end

    it "leaves bookkeeping commands out of the usage", :aggregate_failures do
      usage = payments[:usage]

      expect(usage).not_to include("internal — what a run records about itself")
      expect(usage).not_to include(port_verb[:short])
      expect(usage).to match(/--all\s+also list the \d+ internal/)
    end

    it "lists bookkeeping commands when all is asked for", :aggregate_failures do
      all = usage_for("Payments", all: true)

      expect(all).to include("internal — what a run records about itself")
      expect(all).to include(port_verb[:short])
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

    it "shows one command's arguments", :aggregate_failures do
      help = usage_for("Banking", command: "account.freeze_account")

      expect(help).to include("dispatches Banking::Account.FreezeAccount")
      expect(help).to include("issued by")
      expect(help).to match(/^\s+to\s+String; id of the Account to act on/)
    end

    it "shows every way a command refuses", :aggregate_failures do
      help = usage_for("Banking", command: "account.freeze_account")

      expect(help).to include("refused when:")
      expect(help).to include("status is not open")
    end

    def freeze_help_lines = usage_for("Banking", command: "account.freeze_account").lines.map(&:chomp)

    it "words a given as what must hold, so the command is refused unless it does", :aggregate_failures do
      lines = freeze_help_lines
      unless_at = lines.index("refused unless:")

      expect(unless_at).not_to be_nil
      expect(lines[unless_at + 1]).to eq("  customer is not closed")
    end

    it "keeps a given out of the list of what refuses the command when it holds" do
      lines = freeze_help_lines
      refused_when = lines[(lines.index("refused when:") + 1)..].take_while { |line| line.start_with?("  ") }

      expect(refused_when).not_to include("  customer is not closed")
    end

    # Without `ask:` a question's help prints the command that shares its name.
    it "picks the namespace the caller asked about", :aggregate_failures do
      question = described_class.call(bluebook: registry.bluebook("Banking"),
                                      options:  { command: "account.open", ask: true })[:usage]

      expect(question).to include("reads Banking::Account.Open")
      expect(question).to include("hecks run query account.open")
    end
  end
end
