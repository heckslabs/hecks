require "fileutils"
require "tmpdir"

# A stand-in for the `ScratchBranches` adapter's runner: it records each argv, makes the worktree
# directory `LinkedTree.add!` names, answers a fixed sha, and fails `git apply` when told to. A
# temporary root holds an empty launcher, so no git or launcher is touched.
class ScratchBranchStandIn
  # A command's exit, as `Process::Status` answers it.
  Exit = Struct.new(:success?)

  # What the `CutScratch` ask hands the adapter: the third plant of `tidy-parse`.
  ASKED = { base: { value: "main" }, patch: { value: "diff" }, branch: { value: "tidy-parse" },
            message: { value: "Tidy the parse" }, round: { value: 2 } }.freeze

  attr_reader :calls, :root

  # @param apply_ok [Boolean] whether `git apply` succeeds
  def initialize(apply_ok: true)
    @apply_ok = apply_ok
    @calls = []
    @root = Dir.mktmpdir("scratch-root")
    launcher = File.join(@root, "exe", "hecks")
    FileUtils.mkdir_p(File.dirname(launcher))
    File.write(launcher, "")
    File.chmod(0o755, launcher)
  end

  # @param argv [Array<String>] the command run
  # @return [Array] stdout, stderr and the exit
  def call(argv, **)
    @calls << argv
    make_worktree(argv)
    ok = @apply_ok || !argv.include?("apply")
    [argv.include?("rev-parse") ? "abc123\n" : "", ok ? "" : "error: patch failed", Exit.new(ok)]
  end

  # Removes the temporary root.
  def remove = FileUtils.rm_rf(@root)

  private

  def make_worktree(argv)
    path = argv.find { |arg| arg.start_with?("path.value=") }
    FileUtils.mkdir_p(path.delete_prefix("path.value=")) if path
  end
end
