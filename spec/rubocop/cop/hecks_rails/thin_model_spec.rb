require_relative "../../../support/cop_spec_context"
require_relative "../../../../packages/hecks-rails/lib/rubocop/cop/hecks_rails/thin_model"

# HecksRails/ThinModel ships in packages/hecks-rails; its spec runs here, as the cop needs no Rails.
RSpec.describe RuboCop::Cop::HecksRails::ThinModel do
  include_context "with a Hecks cop under test"

  # A model of `parent` whose body is `line`, annotated with the offense the cop gives for `macro`.
  def offending(line, macro, parent: "Hecks::Rails::Model")
    "class Account < #{parent}\n  #{line}\n  #{"^" * line.size} #{format(described_class::MSG, name: macro)}\nend\n"
  end

  it "flags a validation" do
    expect_offense(offending("validates :number, presence: true", "validates"))
  end

  it "flags a callback" do
    expect_offense(offending("before_save :normalise", "before_save"))
  end

  it "flags an association under a root-anchored parent" do
    expect_offense(offending("belongs_to :source", "belongs_to", parent: "::Hecks::Rails::Model"))
  end

  it "flags a validates_*_of macro" do
    expect_offense(offending("validates_presence_of :number", "validates_presence_of"))
  end

  it "does not flag the aggregate declaration or a presentation method" do
    expect_no_offenses(%(class Account < Hecks::Rails::Model\n  aggregate "Banking.Account"\n  def label; number; end\nend\n))
  end

  it "does not flag a validation in an ActiveRecord model" do
    expect_no_offenses("class Account < ApplicationRecord\n  validates :number, presence: true\nend\n")
  end
end
