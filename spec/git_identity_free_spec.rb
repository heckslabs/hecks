require "spec_helper"
require "open3"

RSpec.describe GitIdentityFree do
  scratch_directory :dir

  def git(*args)
    env = described_class.apply!({ "PATH" => ENV.fetch("PATH") })
    Open3.capture2e(env, "git", *args, chdir: @dir)
  end

  def commit(*identity) = git(*identity, "commit", "--allow-empty", "-m", "x")

  it "empties the global configuration and drops a held identity", :aggregate_failures do
    env = described_class.apply!({ "GIT_AUTHOR_NAME" => "x" })
    expect(File.read(env["GIT_CONFIG_GLOBAL"])).to eq("")
    expect(env.keys & described_class::IDENTITY_KEYS).to be_empty
  end

  it "is in force for this process" do
    expect(ENV.fetch("GIT_CONFIG_NOSYSTEM", nil)).to eq("1")
  end

  it "refuses a commit that names no identity", :aggregate_failures do
    git("init", "-q")
    _out, status = commit
    expect(status).not_to be_success
  end

  it "accepts a commit that names its own identity" do
    git("init", "-q")
    _out, status = commit("-c", "user.name=t", "-c", "user.email=t@t")
    expect(status).to be_success
  end
end
