require "spec_helper"

# The launcher's rename table: an old command or query name resolves to the name it became, its
# arguments translate, and an entry that names nothing is refused when the projection is built.
RSpec.describe Hecks::Projector::CliProjector::Renames do
  subject(:table) { Object.new.extend(described_class) }

  let(:commands) { { "send_train.send" => {}, "review_request.take" => {} } }
  let(:questions) { { "workspace.history" => {} } }

  it "routes a renamed command and a renamed query to their own namespaces" do
    map = table.renamed_aliases(commands, questions,
                                "push_train.push" => "send_train.send", "checkout.log" => "workspace.history")
    expect(map).to eq(command:  { "push_train.push" => "send_train.send" },
                      question: { "checkout.log" => "workspace.history" })
  end

  it "refuses an entry that names neither a command nor a query" do
    expect { table.renamed_aliases(commands, questions, "old.x" => "nothing.here") }
      .to raise_error(Hecks::Bluebook::DSL::Malformed, /names no command or query/)
  end

  it "reads the argument renames an entry translates" do
    renamed = { "push_train.push" => { to: "send_train.send", arguments: { "run" => "key" } } }
    expect(table.renamed_arguments(renamed)).to eq("push_train.push" => { "run" => "key" })
  end

  it "translates an old argument name and leaves the rest of the line alone" do
    resolver = Object.new.extend(Hecks::Adapters::Driving::CliRunner::RenamedNames)
    argv = resolver.translate_arguments({ "run" => "key" }, ["push_train.push", "run=7", "label=x"])
    expect(argv).to eq(["push_train.push", "key=7", "label=x"])
  end
end
