# frozen_string_literal: true

require "spec_helper"
require_relative "support/creates_or_acts_fixture"

# `creates_or_acts` at dispatch: the first Write opens the page, a later one acts on it, and a
# creating command without the word still refuses a taken identity.
RSpec.describe "creates_or_acts at dispatch" do
  include CreatesOrActsFixture

  around { |example| with_fixture_runtime(example) }

  it "opens the record when nothing answers to its identity" do
    expect(write("p-1", "first")).to eq(["first"])
  end

  it "acts on the record its identity already names" do
    write("p-2", "first")
    expect(write("p-2", "second")).to eq(%w[first second])
  end

  it "still refuses a creating command without the word over a taken identity" do
    @runtime.dispatch_flat("CreatesOrActs::Page.Open", title: { value: "p-3" })
    expect { @runtime.dispatch_flat("CreatesOrActs::Page.Open", title: { value: "p-3" }) }
      .to raise_error(Hecks::Runtime::AlreadyExists)
  end
end
