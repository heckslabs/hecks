# spec/hecks/dsl/loads_parse_smoke_parity_spec.rb
#
# Ruby half of the i43 parse-parity toy fixture. Loads
# `spec/parity/behaviors/loads_parse_smoke.behaviors` via the Ruby
# DSL and asserts suite.loads + test.events_include contain the
# same values the Rust side asserts in
# `hecks_life/tests/behaviors_loads_parity_test.rs`. Together they
# prove both parsers produce equivalent IR for the new i43 DSL
# forms, commits 3-5 scope.
#
# [antibody-exempt: parse-parity proof for .behaviors DSL — the Ruby
#  half of the toy fixture cross-check; no runner consumer yet.]
#
$LOAD_PATH.unshift File.expand_path("../../../../lib", __dir__)
require "hecks"
require "hecks/dsl/test_suite_builder"

RSpec.describe "i43 loads_parse_smoke.behaviors — Ruby parse" do
  let(:fixture) do
    File.expand_path(
      "../../parity/behaviors/loads_parse_smoke.behaviors", __dir__,
    )
  end

  it "exists (Rust side reads the same file)" do
    expect(File).to be_file(fixture)
  end

  it "parses suite.loads and test.events_include via Hecks.behaviors" do
    Hecks.instance_variable_set(:@last_test_suite, nil)
    Kernel.load(fixture)
    suite = Hecks.last_test_suite

    expect(suite).not_to be_nil
    expect(suite.name).to eq("LoadsParseSmoke")
    expect(suite.loads).to eq(["foo"])
    expect(suite.tests.size).to eq(1)
    expect(suite.tests[0].events_include).to eq(["Bar"])
  end
end
