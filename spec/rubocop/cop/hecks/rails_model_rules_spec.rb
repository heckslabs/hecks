require_relative "../../../support/cop_spec_context"
require_relative "../../../../lib/rubocop/cop/hecks/rails_model_rules"

RSpec.describe RuboCop::Cop::Hecks::RailsModelRules do
  include_context "with a Hecks cop under test"

  def message(call)
    "`#{call}` declares a rule or an association in a Hecks::Rails::Model. " \
      "State the rule in the bluebook instead; the model is a skin over the aggregate."
  end

  # A second author for a rule the bluebook already states.
  it "flags a validation in a model" do
    expect_offense(<<~RUBY)
      class Account < Hecks::Rails::Model; validates :owner; end
                                           ^^^^^^^^^^^^^^^^ #{message("validates")}
    RUBY
  end

  it "flags a callback in a model" do
    expect_offense(<<~RUBY)
      class Account < Hecks::Rails::Model; before_save :tidy; end
                                           ^^^^^^^^^^^^^^^^^ #{message("before_save")}
    RUBY
  end

  it "flags an association in a model" do
    expect_offense(<<~RUBY)
      class Account < Hecks::Rails::Model; has_many :entries; end
                                           ^^^^^^^^^^^^^^^^^ #{message("has_many")}
    RUBY
  end

  it "allows the aggregate binding" do
    expect_no_offenses('class Account < Hecks::Rails::Model; aggregate "Ledger.Account"; end')
  end

  it "leaves an ordinary class alone" do
    expect_no_offenses("class Report; validates :owner; end")
  end
end
