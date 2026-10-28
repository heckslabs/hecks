require "spec_helper"
require "hecks/composer"
require "hecks/composer/board_edit"

# The event-storming board is read off the booted bluebook, and every action on it is one exact edit
# of the text. Each edit here is applied, then the patched workspace is booted and read back through
# the board, so an edit that wrote bad text would not boot.
RSpec.describe "the Composer's board" do
  let(:dir) { File.expand_path("fixtures/composer/account", __dir__) }
  let(:file) { "ledger.bluebook" }

  before { @buffers = {} }

  def composer = Hecks::Composer

  # Applies one board action to the workspace as the earlier actions left it.
  def edit(action, **args)
    result = composer::Workspace.stage(dir: dir, buffers: @buffers) do |stage|
      composer::BoardEdit.call(stage: stage, action: action, args: args.transform_keys(&:to_s))
    end
    @buffers[result[:path]] = result[:text]
    result
  end

  # The board of the workspace as the actions so far left it, after booting it.
  def board
    composer::Workspace.stage(dir: dir, buffers: @buffers) do |stage|
      outline = composer::Outline.call(stage, composer::Workspace.files(stage))
      chapter = Hecks.boot(stage, install_driving: false, environment: "memory").registry.bluebook("Ledger")
      composer::Board.call(chapter, outline: outline)
    end
  end

  def aggregate(name) = board[:aggregates].find { |note| note[:name] == name }

  def command(owner, name) = aggregate(owner)[:commands].find { |note| note[:name] == name }

  # Whether the board refuses the action, which then changes nothing.
  def refuses?(action, **args)
    edit(action, **args)
    false
  rescue composer::BoardEdit::Refused
    true
  end

  it "reads the aggregates, their commands and what each command emits", :aggregate_failures do
    open = command("Account", "Open")

    expect(board[:aggregates].map { |note| note[:name] }).to eq(["Account"])
    expect(open).to include(goal: "Open an account under a number", emits: ["AccountOpened"])
  end

  it "says where each note is declared in the text", :aggregate_failures do
    expect(aggregate("Account")[:at]).to eq(file: file, line: 4)
    expect(command("Account", "Credit")[:at][:file]).to eq(file)
  end

  it "adds an aggregate, which boots and shows on the board", :aggregate_failures do
    result = edit("add_aggregate", name: "Invoice")

    expect(result[:text].lines[result[:line] - 1]).to include('aggregate "Invoice" do')
    expect(aggregate("Invoice")).to include(name: "Invoice", commands: [])
  end

  it "adds a command with its event to an aggregate", :aggregate_failures do
    edit("add_command", aggregate: "Account", name: "Close", event: "AccountClosed")

    expect(command("Account", "Close")).to include(emits: ["AccountClosed"])
    expect(command("Account", "Close")[:goal]).to eq("Describe Close.")
  end

  it "adds a command to an aggregate it has just added", :aggregate_failures do
    edit("add_aggregate", name: "Invoice")
    edit("add_command", aggregate: "Invoice", name: "Issue", event: "InvoiceIssued")

    expect(command("Invoice", "Issue")).to include(emits: ["InvoiceIssued"])
  end

  it "adds a second event to a command" do
    edit("add_event", aggregate: "Account", command: "Credit", name: "BalanceChanged")

    expect(command("Account", "Credit")[:emits]).to eq(%w[AccountCredited BalanceChanged])
  end

  it "connects an event to a command with a policy", :aggregate_failures do
    edit("add_policy", name: "FreezeWhenOpened", on: "Account.AccountOpened", trigger: "Account.FreezeAccount")

    expect(board[:policies]).to include(a_hash_including(name: "FreezeWhenOpened", on: "Account.AccountOpened",
                                                         trigger: "Account.FreezeAccount"))
  end

  it "deletes a policy" do
    edit("add_policy", name: "FreezeWhenOpened", on: "Account.AccountOpened", trigger: "Account.FreezeAccount")
    edit("delete", kind: "policy", name: "FreezeWhenOpened")

    expect(board[:policies]).to be_empty
  end

  it "deletes a command" do
    edit("delete", kind: "command", aggregate: "Account", name: "FreezeAccount")

    expect(aggregate("Account")[:commands].map { |note| note[:name] }).to eq(%w[Open Credit])
  end

  it "deletes an event from the command that emits it" do
    edit("delete_event", aggregate: "Account", command: "Credit", name: "AccountCredited")

    expect(command("Account", "Credit")[:emits]).to be_empty
  end

  it "deletes a whole aggregate" do
    edit("add_aggregate", name: "Invoice")
    edit("delete", kind: "aggregate", name: "Invoice")

    expect(aggregate("Invoice")).to be_nil
  end

  it "refuses a name that is not a capitalised word, and a name already taken" do
    refusals = [refuses?("add_aggregate", name: "invoice"), refuses?("add_aggregate", name: "Account"),
                refuses?("add_command", aggregate: "Account", name: "Open", event: "AccountOpened")]

    expect(refusals).to all(be(true))
  end

  it "refuses what points at nothing: an unknown aggregate, command, policy target or action" do
    refusals = [refuses?("add_command", aggregate: "Nowhere", name: "Go", event: "Gone"),
                refuses?("add_event", aggregate: "Account", command: "Nothing", name: "Happened"),
                refuses?("add_policy", name: "Loose", on: "Account.AccountOpened", trigger: "Account.Nothing"),
                refuses?("shuffle", name: "Account")]

    expect(refusals).to all(be(true))
  end

  it "refuses an event written without its aggregate, and an event the command already emits" do
    refusals = [refuses?("add_policy", name: "Loose", on: "AccountOpened", trigger: "Account.FreezeAccount"),
                refuses?("add_event", aggregate: "Account", command: "Open", name: "AccountOpened")]

    expect(refusals).to all(be(true))
  end
end
