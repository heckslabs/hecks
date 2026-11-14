# frozen_string_literal: true

require "open3"

# A guard for examples that say a piece of the board starts no process: every way Ruby starts a
# child is refused while the block runs, and the commands that were tried are answered.
module NoChildProcess
  OPEN3 = %i[popen3 popen2 popen2e capture3 capture2 capture2e].freeze

  # @yield the work that must start no process
  # @return [Array<Array<String>>] each command the work tried to start; empty when it tried none
  def children_started
    tried = []
    refuse_children(tried)
    yield
    tried
  end

  private

  def refuse_children(tried)
    refusal = lambda do |*command, **|
      tried << command.grep(String)
      raise Errno::ENOENT, "no child process in this example"
    end
    OPEN3.each { |name| allow(Open3).to receive(name, &refusal) }
    [Process, Kernel].each { |host| allow(host).to receive(:spawn, &refusal) }
    allow(IO).to receive(:popen, &refusal)
  end
end
