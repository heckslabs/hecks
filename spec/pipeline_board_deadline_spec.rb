# frozen_string_literal: true

require "spec_helper"
require "hecks/pipeline_board/adapters/deadline"

# A call that never returns costs its caller the bound and no more.
RSpec.describe Hecks::Adapters::PipelineBoard::Deadline do
  let(:deadline) { described_class }

  it "answers what the block answers" do
    expect(deadline.run(1) { :done }).to eq(:done)
  end

  it "raises what the block raised" do
    expect { deadline.run(1) { raise ArgumentError, "bad" } }.to raise_error(ArgumentError, "bad")
  end

  it "raises Overdue naming the call when the block never returns" do
    expect { deadline.run(0.1, "drawing fill") { Queue.new.pop } }
      .to raise_error(deadline::Overdue, "drawing fill did not answer in 0.1s")
  end

  def thread_stopped_after_overdue
    ran = []
    block = proc { ran << Thread.current } >> proc { Queue.new.pop }
    expect { deadline.run(0.1, &block) }.to raise_error(deadline::Overdue)
    ran.first.join(1)
  end

  it "stops the block's thread" do
    expect(thread_stopped_after_overdue).not_to be_nil
  end
end
