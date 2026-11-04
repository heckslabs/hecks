require "spec_helper"
require_relative "support/git_confirm_launch"

# Each git-state command passes its guard when given the `--confirm` flag. The refusals are in
# git_confirm_spec.rb and the `confirm.value=true` form in git_confirm_value_spec.rb.
RSpec.describe "exe/hecks git-state confirmation by flag", :io do
  include GitConfirmLaunch

  GitConfirmLaunch::GATED.each do |command, args|
    it "passes the guard for #{command} with --confirm" do
      text, _status = launch(command, "--confirm", *args)
      expect(text).not_to include(GitConfirmLaunch::REFUSAL)
    end
  end
end
