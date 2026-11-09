require "spec_helper"
require "hecks/hecks/adapters/console_capture"
require_relative "support/boot_notice_samples"

# A captured failure leads with the command's own words, whichever order the runtime printed its
# boot notices in.
RSpec.describe Hecks::Adapters::ConsoleCapture, ".answer and .answer_apart" do
  include BootNoticeSamples

  def message_of
    yield
  rescue described_class::Failure => e
    e.message
  end

  def refuse_after(notice)
    message_of do
      described_class.answer do
        warn notice
        warn refusal
        exit(1)
      end
    end
  end

  def abort_after(notice)
    message_of do
      described_class.answer_apart do
        warn notice
        abort "no"
      end
    end
  end

  it "leads a captured failure with the command's words", :aggregate_failures do
    message = refuse_after(saga)

    expect(message.lines.first.chomp).to eq(refusal)
    expect(message).to include(Hecks::BootNotices::DIVIDER, "has no save_saga")
  end

  it "leads a failure captured apart with the command's words", :aggregate_failures do
    message = abort_after(outbox)

    expect(message.lines.first.chomp).to eq("no")
    expect(message).to include(Hecks::BootNotices::DIVIDER, "outbox row")
  end

  it "keeps the worktree notice after the cause", :aggregate_failures do
    message = refuse_after(overlay)

    expect(message.lines.first.chomp).to eq(refusal)
    expect(message.lines.last.chomp).to eq(overlay)
  end
end
