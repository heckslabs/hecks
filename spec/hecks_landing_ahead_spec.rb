require "spec_helper"
require_relative "support/landing_ahead_repository"
require "hecks/hecks/adapters/landing/landing_ahead"

# A finished branch lands ahead of a started work item that shares its area, and that item lands
# after it once rebased; only a real merge conflict refuses. Every example builds its own throwaway
# repository; the real one is never read.
RSpec.describe Hecks::Adapters::LandingAhead do
  include LandingAheadRepository

  after { FileUtils.remove_entry(dir) }

  it "lands a finished branch while a started item holds its area, naming that item" do
    two_in_one_area

    expect(land("a")).to match(/onto main.*landed ahead of a started work item: .*in the area of b.*rebases when it lands/)
  end

  it "lands the started item after it, once rebased onto main" do
    two_in_one_area
    land("a")
    commit(tree("b"), "lib/x/b.rb")
    git("rebase", "main", chdir: tree("b"))

    expect(land("b")).to include("onto main")
  end

  it "does not name a rival in a later landing that has none" do
    two_in_one_area
    land("a")
    commit(tree("b"), "lib/x/b.rb")
    started

    expect(land("b")).not_to include("landed ahead")
  end

  it "still refuses a real merge conflict" do
    two_in_one_area
    land("a")
    commit(tree("b"), "lib/x/a.rb", "other")

    expect { land("b") }.to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /conflict/)
  end
end
