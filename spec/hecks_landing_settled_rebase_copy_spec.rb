require "spec_helper"
require "hecks/hecks/adapters/landing/settled_rebase"

# The two vendored methods SettledRebase replaces run the git calls and refusals it copies; a
# change to either in the delivery package fails this, so the copy cannot drift silently.
RSpec.describe "The vendored rebases SettledRebase copies" do
  let(:landing) { File.join(Hecks::Adapters::DeliveryLibrary::ROOT, "git_landing") }

  it "still finds the finisher's rebase it copies" do
    expect(File.read(File.join(landing, "finisher.rb"))).to include(
      "@git.capture(*replay_identity(@checkout), \"rebase\", *rebase_range, chdir: @checkout)",
      "\"conflict: rebasing \#{@branch} onto \#{@onto} \#{abandon_rebase(@checkout, result)}; nothing changed\""
    )
  end

  it "still finds the train's rebase it copies" do
    expect(File.read(File.join(landing, "train.rb"))).to include(
      "@git.capture(\"rebase\", @onto, chdir: tree.path)", "@git.capture(\"rebase\", \"--abort\", chdir: tree.path)",
      "\"\#{branch} does not rebase onto \#{@onto}: \#{Train.tail(result.out, 2)}\""
    )
  end
end
