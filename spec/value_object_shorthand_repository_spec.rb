# frozen_string_literal: true

require "spec_helper"
require "hecks/tools/value_object_shorthand"

# The rule, held over the repository itself: a value object block that only wraps one plain `value`
# attribute is written as the shorthand, so the block form means the value object has more to say.
# `exe/hecks style_run.shorten_value_objects! --confirm` rewrites any that appear.
RSpec.describe "the value object shorthand across the repository", :repo_scan do
  it "leaves no bare block outside the held examples" do
    root = File.expand_path("..", __dir__)
    expect(Hecks::Tools::ValueObjectShorthand.shorten([], root: root, write: false)).to eq({})
  end
end
