require "spec_helper"
require "hecks/adapters/driving/resident/server"

# Forks a child whose standard error has no reader, runs the block in it and returns its status.
module ClosedStderrChild
  def self.status_of(&)
    reader, writer = IO.pipe
    pid = fork { run_with(writer, reader, &) }
    writer.close
    reader.close
    Process.wait2(pid).last.exitstatus
  end

  def self.run_with(writer, reader)
    reader.close
    $stderr.reopen(writer)
    yield
  end
end

# A roll runs as a resident child whose standard error is the launching client's pipe. When
# that client has exited, writing to it raises Errno::EPIPE; the child still ends with the status
# of its line, never with a failure of its own diagnostic.
RSpec.describe "a resident child whose standard error is a closed pipe" do
  let(:worker) { Hecks::Adapters::Driving::Resident::Worker }

  # Leaves from inside a rescue, so the worker finds an uncaught error to report.
  def fail_then(worker)
    raise "boom"
  rescue StandardError
    worker.leave
  end

  it "leaves with status 1 when an uncaught error cannot be reported" do
    expect(ClosedStderrChild.status_of { fail_then(worker) }).to eq(1)
  end

  it "leaves with status 0 when the flush finds the pipe closed" do
    expect(ClosedStderrChild.status_of { worker.leave }).to eq(0)
  end

  it "tolerates a broken pipe and a closed stream" do
    results = [Errno::EPIPE, IOError].map { |error| worker.tolerating_closed_pipe { raise error } }
    expect(results).to eq([nil, nil])
  end

  it "still raises any other error" do
    expect { worker.tolerating_closed_pipe { raise ArgumentError, "real" } }.to raise_error(ArgumentError)
  end
end
