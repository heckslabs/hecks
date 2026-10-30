require "spec_helper"
require "open3"
require "tmpdir"
require "hecks/quality_control/cli/qa_tick/preflight"

# The tick's start from `origin/main`, in a throwaway repository with its own bare `origin`.
RSpec.describe Hecks::QualityControlCli::QaTick::Preflight do
  # The smallest host the module needs: the checkout it works in.
  let(:host_class) do
    Class.new do
      include Hecks::QualityControlCli::QaTick::Preflight

      public :rebase_on_origin_main

      def initialize(repo_dir) = @repo_dir = repo_dir
    end
  end

  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      example.run
    end
  end

  def sh(*argv, chdir: File.join(@dir, "work"))
    out, status = Open3.capture2e(*argv, chdir: chdir)
    raise "#{argv.join(" ")}: #{out}" unless status.success?

    out.strip
  end

  def commit(file, text)
    File.write(File.join(@dir, "work", file), text)
    sh("git", "add", file)
    sh("git", "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", file)
  end

  # `main` pushed to origin, then a local side branch merged into it: a checkout that already
  # holds `origin/main` and carries a merge commit of its own.
  def checkout_holding_origin_with_a_merge
    sh("git", "init", "-q", "--bare", "-b", "main", File.join(@dir, "origin.git"), chdir: @dir)
    sh("git", "clone", "-q", File.join(@dir, "origin.git"), "work", chdir: @dir)
    commit("a.txt", "a")
    sh("git", "push", "-q", "origin", "HEAD:main")
    sh("git", "checkout", "-qb", "side")
    commit("b.txt", "b")
    sh("git", "checkout", "-q", "main")
    commit("c.txt", "c")
    sh("git", "-c", "user.name=t", "-c", "user.email=t@t", "merge", "-q", "--no-ff", "-m", "merge", "side")
  end

  it "leaves a checkout that already holds origin/main as it is, merge commits and all", :aggregate_failures do
    checkout_holding_origin_with_a_merge
    head = sh("git", "rev-parse", "HEAD")

    expect { host_class.new(File.join(@dir, "work")).rebase_on_origin_main }.to output(/at /).to_stdout
    expect(sh("git", "rev-parse", "HEAD")).to eq(head)
  end
end
