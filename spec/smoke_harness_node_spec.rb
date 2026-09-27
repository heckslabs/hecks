require "open3"

# Runs the smoke harness's own tests (spec/js/smoke_harness.test.js) under node's
# built-in test runner, so a change to the emitted JavaScript is checked by the
# ordinary suite. They use a fake site on a local port and need no network.
RSpec.describe "the smoke harness (node)", :io do
  JS_TEST_FILE = File.join(InMemoryDomain::ROOT, "spec/js/smoke_harness.test.js").freeze

  it "passes its node tests" do
    node, = Open3.capture2("sh", "-c", "command -v node")
    skip "node is not installed" if node.strip.empty?

    output, status = Open3.capture2e(node.strip, "--test", JS_TEST_FILE)

    expect(status).to be_success, output
  end
end
