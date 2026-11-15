require_relative "process_tree"

# Names the process a spec left behind. A group that starts a resident or another long-lived
# process registers its pid with {watch}; when the suite ends, every watched process that still
# stands, and every process still under this one, is ended and named in a failure. A shard step
# that would have hung on a child holding it open then fails at once, with the process named.
module ChildProcessGuard
  # Raised at the end of the suite, naming each process a spec left behind.
  class Left < StandardError; end

  @watched = []

  class << self
    # @param pid [Integer] a process a spec started and means to stop
    # @return [Integer] the pid
    def watch(pid)
      @watched << pid unless @watched.include?(pid)
      pid
    end

    # Ends what is left and says what it was.
    #
    # @return [void]
    # @raise [Left] naming each process that was still standing
    def check
      left = standing
      return if left.empty?

      left.each_key { |pid| ProcessTree.end_tree(pid) }
      raise Left, "a spec left a process behind: #{left.map { |pid, command| "#{pid} (#{command})" }.join(", ")}"
    end

    private

    def standing
      under = ProcessTree.descendants(Process.pid).map(&:pid)
      (@watched + under).uniq.select { |pid| ProcessTree.alive?(pid) }.to_h { |pid| [pid, ProcessTree.command(pid)] }
    end
  end
end

RSpec.configure do |config|
  config.after(:suite) { ChildProcessGuard.check }
end
