require "rspec/expectations"

# `expect { account.freeze_account! }.to be_refused_with("the balance is zero")`
#
# Passes when the block raises a `Hecks::Refused` whose message contains the text, and fails with
# what was raised otherwise. Naming no text accepts any refusal.
RSpec::Matchers.define :be_refused_with do |text = nil|
  supports_block_expectations

  match do |block|
    block.call
    false
  rescue Hecks::Refused => e
    @refusal = e
    text.nil? || e.message.include?(text)
  end

  failure_message do
    next "expected a refusal, but nothing was refused" unless @refusal

    "expected a refusal containing #{text.inspect}, got #{@refusal.message.inspect}"
  end
end
