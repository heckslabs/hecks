# frozen_string_literal: true

require "tmpdir"
require "open3"
require "rbconfig"
require "fileutils"

# A scratch repository whose one check spec passes on a full history and fails on a shallow one.
# `main` holds two commits and the spec; branch `work/a` changes one file on top of them in `tree`.
# The real repository, `~/.claude` and GitHub are never touched.
module ShallowRepo
  DEPTH_SPEC = "RSpec.describe('history') { it('is deep') { expect(`git rev-list --count HEAD`.to_i).to be > 1 } }\n"

  def self.included(base)
    base.after { FileUtils.remove_entry(dir) }
  end

  def dir = @dir ||= File.realpath(Dir.mktmpdir("hecks-shallow"))

  def repo = File.join(dir, "main")

  def tree = File.join(dir, "tree")

  def failure = Hecks::Adapters::ConsoleCapture::Failure

  def runner = { specs: ["spec/depth_spec.rb"], command: [RbConfig.ruby, "-S", "rspec", "--no-color"] }

  def git(*, chdir: repo)
    out, status = Open3.capture2e("git", "-c", "user.name=t", "-c", "user.email=t@t", *, chdir: chdir)
    raise out unless status.success?

    out
  end

  def commit(where, file, text = "x")
    FileUtils.mkdir_p(File.dirname(File.join(where, file)))
    File.write(File.join(where, file), text)
    git("add", ".", chdir: where)
    git("commit", "-m", file, chdir: where)
  end

  def build_repo(changed)
    FileUtils.mkdir_p(repo)
    git("init", "-b", "main")
    commit(repo, "spec/depth_spec.rb", DEPTH_SPEC)
    commit(repo, "README", "two")
    git("worktree", "add", "-b", "work/a", tree)
    commit(tree, changed)
  end

  def shallow(**tune) = shallow_in(tree, "work/a", "main", **tune)

  def shallow_in(checkout, branch, onto, **tune)
    Hecks::Adapters::GitShallowCheck.new(**runner, **tune).shallow_check(checkout: checkout, branch: branch, onto: onto)
  end

  def switch(state) = Hecks::Adapters::GitShallowCheck.new.shallow_switch(checkout: tree, state: { value: state })

  def green
    done = instance_double(Process::Status, success?: true)
    Hecks::Adapters::Shell::Result.new(%({"status": "completed"}), "", done)
  end

  def finish
    check = ->(checkout, branch, onto) { shallow_in(checkout, branch, onto) }
    land = Hecks::Adapters::GitLanding.new
    land.finish_branch(checkout: tree, branch: "work/a", onto: "main", gate: ->(_) { green }, shallow: check)
  end
end
