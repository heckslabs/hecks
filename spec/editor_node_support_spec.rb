require "spec_helper"
require_relative "support/editor_node"

# The transformed `@hecks/client` that the node editor specs share, built once per process in a
# temp directory (spec/support/editor_node.rb).
RSpec.describe EditorNode do
  before { skip "node cannot strip TypeScript types here" unless described_class.available? }

  # Starts a child that leaves the way a spec's forked worker does: by exiting normally, which
  # runs the `at_exit` hooks it inherited.
  def exit_a_forked_child
    Process.wait(fork { exit(0) })
  end

  it "keeps the client directory when a forked child of the spec process exits", :aggregate_failures, :process do
    client = described_class.transformed_client
    exit_a_forked_child

    expect(Dir.exist?(client)).to be(true)
    expect(described_class.transformed_client).to eq(client)
  end

  it "builds the client again if its directory has gone", :aggregate_failures, :process do
    gone = described_class.transformed_client
    FileUtils.rm_rf(File.dirname(gone))

    expect(Dir.exist?(described_class.transformed_client)).to be(true)
    expect(described_class.transformed_client).not_to eq(gone)
  end
end
