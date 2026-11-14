# Gives every example the working directory it started in. A landing's finish leaves the
# worktree it retires for good (`Dir.chdir`, in the vendored delivery package), so a spec that
# runs one in this process would leave the process inside a scratch repository that the spec then
# removes. Every later example of the process would then fail on `getcwd`, and the group would
# end without a summary.
module WorkingDirectoryGuard
  # The directory the suite process started in, used when the current one is already gone.
  START = Dir.pwd.freeze

  # Runs the example, then returns the process to the directory it held before it.
  #
  # @param example [RSpec::Core::Example::Procsy] the example to run
  # @return [void]
  def self.around(example)
    held = held_directory
    example.run
  ensure
    Dir.chdir(held) if held && Dir.exist?(held)
  end

  # @return [String] the process's working directory, or the starting one when it was removed
  def self.held_directory
    Dir.pwd
  rescue Errno::ENOENT
    START
  end
end

RSpec.configure do |config|
  config.around { |example| WorkingDirectoryGuard.around(example) }
end
