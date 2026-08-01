require "spec_helper"

# rust/src/bluebook/ir_structs.rs is bin/ir_structs's output — Rust STRUCT
# declarations projected from the thirteen categories the language uses to
# describe itself, plus the `derived:` column of assembly/contracts.rb. Checked
# in for the same reason ir_vocabulary.rs is: Rust cannot run the Ruby DSL to
# read the language, so it compiles against a copy.
#
# A copy nothing compares is a copy that drifts — the finding this whole arc
# keeps making, and the reason the seven structs in that file are only seven.
# The Rust build succeeds against a stale copy just as happily as a fresh one,
# so nothing but this holds the checked-in file to what the generator produces
# right now.
RSpec.describe "the projected Rust IR structs" do
  it "rust/src/bluebook/ir_structs.rs matches bin/ir_structs's current output" do
    root       = InMemoryDomain::ROOT
    checked_in = File.read(File.join(root, "rust/src/bluebook/ir_structs.rs"))
    current    = `#{File.join(root, 'bin/ir_structs')}`

    expect(checked_in).to eq(current),
                          "rust/src/bluebook/ir_structs.rs is stale — regenerate with " \
                          "`bin/ir_structs > rust/src/bluebook/ir_structs.rs`"
  end
end
