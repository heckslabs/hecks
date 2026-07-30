require "spec_helper"
require "json"

# rust/src/bluebook/expression/operators.json and rust/src/runtime/mutation_ops.json
# are bin/operators' and bin/mutation_ops' output, checked in and embedded at
# compile time because Rust cannot run the Ruby DSL to read Evaluator::OPERATORS
# / CommandRules::MUTATION_OPS directly (see each script's own comment).
# Nothing else catches a forgotten regeneration — the Rust build succeeds
# either way, it would just be reading a stale table — so this holds each
# checked-in file equal to what its script produces right now.
RSpec.describe "the exported tables" do
  {
    "rust/src/bluebook/expression/operators.json" => "bin/operators",
    "rust/src/runtime/mutation_ops.json"           => "bin/mutation_ops"
  }.each do |checked_in_path, script|
    it "#{checked_in_path} matches #{script}'s current output" do
      root       = InMemoryDomain::ROOT
      checked_in = File.read(File.join(root, checked_in_path))
      current    = `#{File.join(root, script)}`

      expect(checked_in).to eq(current),
        "#{checked_in_path} is stale — regenerate with `#{script} > #{checked_in_path}`"
    end
  end
end
