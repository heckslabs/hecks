# frozen_string_literal: true

require "spec_helper"

# A beat keeps the place for its process, so the examples must not hand it on to each other.
RSpec.describe "the Beating place between examples", order: :defined do
  it("is taken by an example whose beat holds it") do
    Hecks::Adapters::Beating.held = File.open(File::NULL)

    expect(Hecks::Adapters::Beating.held).not_to be_nil
  end

  it("is not held when the next example starts") { expect(Hecks::Adapters::Beating.held).to be_nil }
end
