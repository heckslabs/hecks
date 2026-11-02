require "open3"
require "hecks/hecks/adapters/red_flag_marker"

# Keeps every spec off the owner's live state beyond the ledger (`LiveLedgerGuard`): the event
# tap (`~/.claude/hecks-dev/events.jsonl`, which the pipeline board reads) and the red flag in
# the checkout's own git directory (`hecks-red-flag.json`, which every landing and boarding
# reads). spec_helper points the tap at the run's temporary file (`HECKS_EVENT_TAP`), children
# included, and the Memory overlay switches it off in this process; the runtime's tap refuses
# the live log outright, so a spec that gets around both fails by name. The flag's marker
# refuses the checkout's git directory, so a spec with no scratch repository fails by name, and
# every example is bracketed by a look at the checkout's flag: one that moved during the
# example, from this process or a child, fails it. The tap gets no such look: every hecks
# command of every session on the machine appends to it, so a look at the file would blame a
# spec for another session's work.
module LiveStateGuard
  # Raised when a spec reaches for live state.
  class Violation < StandardError; end

  # The checkout the specs belong to, whatever worktree they run from.
  ROOT = File.expand_path("../..", __dir__)

  # @return [String] the live event tap, as hecks.world names it
  def self.tap_path = File.join(LiveLedgerGuard.dir, "events.jsonl")

  # @return [String] the checkout's common git directory, shared by every worktree
  def self.git_dir
    @git_dir ||= begin
      out, status = Open3.capture2("git", "rev-parse", "--path-format=absolute", "--git-common-dir", chdir: ROOT)
      File.expand_path(status.success? ? out.strip : File.join(ROOT, ".git"))
    end
  end

  # @return [String] the checkout's own red flag
  def self.flag_path = File.join(git_dir, Hecks::Adapters::RedFlagMarker::FILE)

  # @param path [String] a git directory a marker is about to use
  # @return [Boolean] whether it is the checkout's own, or a worktree's under it
  def self.checkout?(path)
    expanded = File.expand_path(path.to_s)
    expanded == git_dir || expanded.start_with?("#{git_dir}/")
  end

  # Prepended to the runtime's event tap, refusing the live log.
  module TapRefusal
    def initialize(path:, **options)
      if LiveLedgerGuard.live?(path)
        raise Violation, "a spec opened the live event tap #{path}; boot with boot_hecks_in_memory, " \
                         "or build a world whose event_log names a temporary path"
      end

      super
    end
  end

  # Prepended to the red flag's marker, refusing the checkout's own flag.
  module FlagRefusal
    def initialize(git_dir, **options)
      if LiveStateGuard.checkout?(git_dir)
        raise Violation, "a spec reached the checkout's red flag in #{git_dir}; " \
                         "build a scratch repository and name it as the checkout"
      end

      super
    end
  end

  # A look at a set of files: each one's size and change time, or its absence.
  class Watch
    # @param paths [Array<String>] the files to look at
    def initialize(paths) = @paths = paths

    # @return [Hash{String => Array, nil}] each file's stamp now
    def snapshot = @paths.to_h { |path| [path, stamp(path)] }

    # @param before [Hash{String => Array, nil}] an earlier snapshot
    # @return [Array<String>] the files whose stamp moved since it
    def changed(before) = snapshot.reject { |path, stamp| before[path] == stamp }.keys

    private

    def stamp(path)
      stat = File.stat(path)
      [stat.size, stat.mtime]
    rescue Errno::ENOENT
      nil
    end
  end
end

Hecks::Runtime::EventTap.prepend(LiveStateGuard::TapRefusal)
Hecks::Adapters::RedFlagMarker.prepend(LiveStateGuard::FlagRefusal)

RSpec.configure do |config|
  watch = LiveStateGuard::Watch.new([LiveStateGuard.flag_path])
  config.around do |example|
    before = watch.snapshot
    example.run
    moved = watch.changed(before)
    next if moved.empty?

    raise LiveStateGuard::Violation, "the example moved the checkout's red flag #{moved.join(", ")}; " \
                                     "build a scratch repository and name it as the checkout"
  end
end
