require_relative "../../../support/cop_spec_context"
require_relative "../../../../lib/rubocop/cop/hecks/git_history_through_the_port"

# One line of source per way of reading the history, each of which the cop flags once.
GIT_HISTORY_READS = {
  "git log run word by word"                => %(Open3.capture2("git", "log", "-1", "--format=%ct")),
  "log passed to a helper beside an option" => %(read("log", "--format=%h %s", range)),
  "log beside an interpolated option"       => %(git(dir, "log", "-\#{count}", "--format=%s")),
  "rev-list passed to any call"             => %(@git.capture("rev-list", "--count", range, chdir: dir)),
  "the words of a %w list"                  => "system(*%w[git log -1])",
  "the words of an array"                   => %(run(["git", "rev-list", head])),
  "a backtick command"                      => "`git rev-list --count HEAD`",
  "a command line handed to the shell"      => %(Open3.capture2e("git log -1")),
  "a command line with options before log"  => %(system("git -C \#{dir} log -1"))
}.freeze

# One line of source per look-alike the cop leaves alone.
GIT_HISTORY_LOOK_ALIKES = {
  "a comparison with the word log" => %(verb == "log"),
  "a hash value"                   => %({ "verb" => "log" }),
  "a call with no git word beside" => %(logger.tagged("log")),
  "a message that names git log"   => %(raise Failure, "git log failed"),
  "another git command"            => %(read("status", "--porcelain")),
  "another backtick git command"   => "`git diff --stat`"
}.freeze

RSpec.describe RuboCop::Cop::Hecks::GitHistoryThroughThePort do
  include_context "with a Hecks cop under test"

  def offenses_for(source, path = "lib/hecks/unlisted_library_file.rb")
    inspect_source("#{source}\n", path)
  end

  GIT_HISTORY_READS.each do |name, source|
    it("flags #{name}") { expect(offenses_for(source).size).to eq(1) }
  end

  GIT_HISTORY_LOOK_ALIKES.each do |name, source|
    it("does not flag #{name}") { expect(offenses_for(source)).to be_empty }
  end

  it "names the command in the message" do
    expect(offenses_for(%(read("rev-list", range))).first.message).to start_with("`git rev-list` reads")
  end

  it "does not flag a file the baseline lists" do
    expect(offenses_for(%(read("rev-list", range)), described_class.baseline.first)).to be_empty
  end
end
