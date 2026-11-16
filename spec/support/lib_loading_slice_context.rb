require_relative "lib_loading_slice"

# A slice whose spawner and load reading are doubles, so a spec runs it with no child process.
RSpec.shared_context "with a faked lib-loading slice" do
  subject(:slice) { Object.new.extend(LibLoadingSlice) }

  let(:status) { instance_double(Process::Status, success?: true) }

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("CI").and_return(nil)
    allow(slice).to receive(:pause)
    allow(slice).to receive(:load_in_subprocess).and_return(["", "", status])
  end

  def loaded(*readings) = allow(slice).to receive(:machine_load).and_return(*readings)
end
