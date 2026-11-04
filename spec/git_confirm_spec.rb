require "spec_helper"
require_relative "support/git_confirm_launch"

# Without a confirmation each git-state command refuses, in one wording, and the read-only status
# runs bang-less. The same commands pass the guard in git_confirm_flag_spec.rb and
# git_confirm_value_spec.rb; spec/support/git_confirm_launch.rb says why they are three files.
RSpec.describe "exe/hecks git-state confirmation", :io do
  include GitConfirmLaunch

  GitConfirmLaunch::GATED.each do |command, args|
    it "refuses #{command} without --confirm, and says so", :aggregate_failures do
      text, status = launch(command, *args)
      expect(text).to include(GitConfirmLaunch::REFUSAL)
      expect(status).not_to eq(0)
    end
  end

  it "runs the read-only status without --confirm", :aggregate_failures do
    text, _status = launch("Checkout.status")
    expect(text).not_to include("needs --confirm")
  end
end
