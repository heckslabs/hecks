require "spec_helper"
require "open3"
require "tmpdir"

# The pre-push hook while the candidate gate is on (ADR 0181): a push of main goes through only as
# the promotion the train or Candidate.promote! carries (`-c hecks.candidatePromotion=<commit>`
# naming the pushed commit) or under the owner's HECKS_OWNER_PUSH; the candidate ref is held to the
# train like main; off, nothing changes. Temp repositories, a local bare remote, and a stub `bundle`
# so the quick gate itself is not run.
RSpec.describe "the pre-push hook under the candidate gate", :io do
  GATE_REFUSAL = "main moves only by promotion of a green candidate".freeze

  let(:scratch) { Dir.mktmpdir("hecks-candidate-hook") }
  let(:work) { File.join(scratch, "work") }
  let(:hooks) { File.expand_path("../.githooks", __dir__) }

  def run(*args, env: {}, dir: work)
    full = { "GIT_AUTHOR_NAME" => "A", "GIT_AUTHOR_EMAIL" => "a@x.test", "GIT_COMMITTER_NAME" => "A",
             "GIT_COMMITTER_EMAIL" => "a@x.test", "PATH" => "#{File.join(scratch, "bin")}:#{ENV.fetch("PATH")}" }
    Open3.capture3(full.merge(env), "git", *args, chdir: dir)
  end

  def git(*args, **opts) = run(*args, **opts).tap { |_o, e, s| raise "git #{args}: #{e}" unless s.success? }.first

  def head = git("rev-parse", "main").strip

  # A push of main as the train carries it, with the promotion named when `promotion` is given.
  def push_main(promotion: nil, env: {})
    config = ["-c", "hecks.trainCarry=#{head}"]
    config += ["-c", "hecks.candidatePromotion=#{promotion}"] if promotion
    run(*config, "push", "-q", "origin", "main", env: env)
  end

  def commit(name)
    File.write(File.join(work, name), name)
    git("add", name)
    git("commit", "-q", "-m", name)
  end

  before do
    FileUtils.mkdir_p(File.join(scratch, "bin"))
    File.write(File.join(scratch, "bin/bundle"), "#!/bin/sh\nexit 0\n")
    FileUtils.chmod(0o755, File.join(scratch, "bin/bundle"))
    git("init", "-q", "--bare", "-b", "main", "origin.git", dir: scratch)
    git("clone", "-q", "origin.git", work, dir: scratch)
    git("checkout", "-q", "-b", "main")
    git("config", "core.hooksPath", hooks)
    git("config", "hecks.candidateGate", "true")
    commit("first")
  end

  after { FileUtils.remove_entry(scratch) }

  it "refuses a push of main that is not a promotion, by name" do
    _out, err, status = push_main

    expect([status.success?, err]).to match([false, include(GATE_REFUSAL, "Candidate.promote!", "HECKS_OWNER_PUSH=<reason>")])
  end

  it "pushes nothing when it refuses" do
    push_main

    expect(git("ls-remote", "origin", "refs/heads/main")).to be_empty
  end

  it "refuses a promotion that names another commit than the one pushed" do
    _out, _err, status = push_main(promotion: "0" * 40)

    expect(status.success?).to be(false)
  end

  it "lets the promotion of the pushed commit through" do
    _out, _err, status = push_main(promotion: head)

    expect(status.success?).to be(true)
  end

  it "lets the owner's named reason through" do
    _out, _err, status = push_main(env: { "HECKS_OWNER_PUSH" => "the gate is stuck" })

    expect(status.success?).to be(true)
  end

  it "holds the candidate ref to the train: a plain push of it is refused" do
    _out, err, status = run("push", "-q", "origin", "main:refs/heads/candidate")

    expect([status.success?, err]).to match([false, include("a plain git push of main is refused")])
  end

  it "lets the train's push of the candidate ref through" do
    _out, _err, status = run("-c", "hecks.trainCarry=#{head}", "push", "-q", "origin", "main:refs/heads/candidate")

    expect(status.success?).to be(true)
  end

  it "changes nothing while the gate is off" do
    git("config", "hecks.candidateGate", "false")
    _out, _err, status = push_main

    expect(status.success?).to be(true)
  end

  it "leaves another branch alone" do
    _out, _err, status = run("push", "-q", "origin", "HEAD:refs/heads/topic")

    expect(status.success?).to be(true)
  end
end
