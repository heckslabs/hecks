# frozen_string_literal: true

require "fileutils"
require "open3"
require "tmpdir"

# Commits in a temporary repository that uses the repo's own `.githooks`.
module RunTrailerRepo
  AUTHOR = { "GIT_AUTHOR_NAME" => "Miette", "GIT_AUTHOR_EMAIL" => "miette@embryonaut.ai",
             "GIT_COMMITTER_NAME" => "Miette", "GIT_COMMITTER_EMAIL" => "miette@embryonaut.ai" }.freeze

  def commit(env, message = "Add thing")
    Open3.capture3(AUTHOR.merge(env), "git", "commit", "-q", "--allow-empty", "-m", message, chdir: work)
    git("log", "-1", "--format=%B").first
  end

  def git(*) = Open3.capture3("git", *, chdir: work)

  def hooked_repository
    git("init", "-q", "-b", "the-item")
    git("config", "core.hooksPath", File.expand_path("../../.githooks", __dir__))
  end
end
