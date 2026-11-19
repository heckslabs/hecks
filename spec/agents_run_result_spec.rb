require "spec_helper"
require_relative "support/stand_in_claude"
require_relative "support/wakes_coder_helpers"
require_relative "support/run_result_helpers"

# A coder run's result as its closing report states it: verified, unverified or blocked, or
# unstated when the report names no result code, so a bare `stopped` never reads as done.
RSpec.describe "a coder run's result code" do
  include_context "with a stand-in claude"
  include WakesCoderHelpers
  include RunResultHelpers

  before(:all) { @hecks = boot_hecks_in_memory }

  before { fake_runner([]) }

  RunResultHelpers::CLOSINGS.each do |name, (state, report, code)|
    it "records #{name} as #{code}" do
      coder_closes(key = "c-#{name.tr(" ", "-")}", state, report)
      expect(code_of(key)).to eq(code)
    end
  end

  it "reads the result of a coder whose session went idle having said its report" do
    coder_idles("c-idle", "Result: verified")
    expect(code_of("c-idle")).to eq("verified")
  end

  it "closes nothing while the coder waits on its plan review" do
    coder_waits_on_review("c-review")
    expect(code_of("c-review")).to be_nil
  end
end
