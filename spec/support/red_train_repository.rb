# frozen_string_literal: true

require "fileutils"
require "open3"
require "securerandom"
require "tmpdir"
require_relative "hecks_launcher_stub"

# A throwaway repository holding a train: landings on local main that `origin/main` does not hold.
# A landing that adds `bad.rb` turns the example `spec/bad_spec.rb:3` red from there on, and one
# that adds `worse.rb` does the same for `spec/worse_spec.rb:3`; the probes of a search and the
# checks of a verification are stand-ins that read those files, so nothing runs.
module RedTrainRepository
  # The failing example each marker file turns red.
  MARKERS = { "spec/bad_spec.rb:3" => "bad.rb", "spec/worse_spec.rb:3" => "worse.rb" }.freeze

  def git(*, chdir: repo)
    out, status = Open3.capture2e("git", "-c", "user.name=t", "-c", "user.email=t@t", *, chdir: chdir)
    raise out unless status.success?

    out
  end

  def open_repository
    git("init", "--bare", "-b", "main", File.join(dir, "origin.git"), chdir: dir)
    git("clone", "-q", File.join(dir, "origin.git"), repo, chdir: dir)
    git("config", "user.name", "t")
    git("config", "user.email", "t@t")
    HecksLauncherStub.place(repo)
    commit("start")
    git("push", "-q", "origin", "main")
  end

  def commit(message)
    git("add", ".")
    git("commit", "-q", "-m", message)
  end

  # Merges a branch holding one file into local main, as a landing does.
  #
  # @return [String] the merge commit
  def land(name, file = "#{name}.rb")
    git("checkout", "-q", "-b", name)
    File.write(File.join(repo, file), SecureRandom.hex)
    commit(name)
    git("checkout", "-q", "main")
    git("merge", "-q", "--no-ff", "-m", "Merge branch '#{name}'", name)
    head
  end

  def head = git("rev-parse", "main").strip

  # Five landings ahead of `origin/main`; the third adds the bad file.
  #
  # @return [String] the train's head
  def train_of_five
    %w[one two].each { |name| land(name) }
    @bad = land("three", "bad.rb")
    %w[four five].each { |name| land(name) }
    head
  end

  # The probes of a search: an example is red where its marker file is, everywhere with
  # `everywhere`, and nowhere with `green`. The checks of a verification pass.
  def stand_in(everywhere: false, green: false)
    Hecks::Adapters::MainVerification.runner = ->(_argv, chdir:) { [true, chdir] }
    Hecks::Adapters::MainVerification.specs = lambda do |directory, examples|
      red = !green && (everywhere || File.exist?(File.join(directory, MARKERS.fetch(examples.first))))
      raise Hecks::Adapters::ConsoleCapture::Failure, "failing spec: spec/bad_spec.rb\n  1) breaks the build" if red
    end
  end

  def subjects = git("log", "--format=%s", "-8").lines.map(&:strip)

  def reverts = subjects.grep(/\ARevert/)
end
