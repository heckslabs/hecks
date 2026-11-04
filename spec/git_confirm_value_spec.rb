require "spec_helper"
require_relative "support/git_confirm_launch"

# Each git-state command passes its guard when given `confirm.value=true`. The refusals are in
# git_confirm_spec.rb and the `--confirm` flag in git_confirm_flag_spec.rb.
RSpec.describe "exe/hecks git-state confirmation by value", :io do
  include GitConfirmLaunch

  GitConfirmLaunch::GATED.each do |command, args|
    it "passes the guard for #{command} with confirm=true" do
      text, _status = launch(command, "confirm.value=true", *args)
      expect(text).not_to include(GitConfirmLaunch::REFUSAL)
    end
  end
end
