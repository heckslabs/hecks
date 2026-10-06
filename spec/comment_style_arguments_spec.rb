require "spec_helper"
require "tmpdir"
require "fileutils"
require "open3"
require "hecks/tools"
require "hecks/tools/comment_style"

# The comment linter's command line: paths after `--` are paths, and `--code-unchanged` fails
# closed for any file it cannot compare with the ref.
RSpec.describe Hecks::Tools::CommentStyle, ".main and .code_changed_since" do
  around do |example|
    Dir.mktmpdir("comment-style-args-") do |dir|
      @dir = File.realpath(dir)
      Dir.chdir(@dir) { example.run }
    end
  end

  def run_vcs(*args)
    _out, status = Open3.capture2e("git", "-c", "user.name=t", "-c", "user.email=t@example.com", *args)
    raise "git #{args.join(" ")} failed" unless status.success?
  end

  def quiet
    original = $stdout
    $stdout = StringIO.new
    yield
  ensure
    $stdout = original
  end

  describe "`--`" do
    it "reads what follows as paths, so a path named like a flag cannot switch the mode" do
      File.write("a.rb", "# HELLO there\nx = 1\n")

      expect { quiet { described_class.main(["--check", "--", "--fix", "a.rb"]) } }
        .to raise_error(SystemExit) { |error| expect(error.status).not_to eq(0) }
      expect(File.read("a.rb")).to eq("# HELLO there\nx = 1\n")
    end

    it "refuses a path that does not exist" do
      expect { quiet { described_class.main(["--check", "--", "nowhere.rb"]) } }
        .to raise_error(SystemExit)
    end

    it "leaves an ordinary check of an existing path working" do
      File.write("a.rb", "x = 1\n")

      expect(quiet { described_class.main(["--check", "--", "a.rb"]) }).to eq(0)
    end
  end

  describe "--code-unchanged" do
    before do
      run_vcs("init", "-q", ".")
      File.write("a.rb", "# one\nx = 1\n")
      run_vcs("add", "a.rb")
      run_vcs("commit", "-q", "-m", "a")
    end

    def changed(*paths, ref: "HEAD") = described_class::Run.new(paths, baseline: {}).code_changed_since(ref)

    it "treats a comment-only edit as unchanged, by relative or absolute path" do
      File.write("a.rb", "# two\nx = 1\n")

      expect(changed("a.rb")).to eq([])
      expect(changed(File.join(@dir, "a.rb"))).to eq([])
    end

    it "treats an edit to the code as changed" do
      File.write("a.rb", "# one\nx = 2\n")

      expect(changed("a.rb")).to eq(["a.rb"])
    end

    it "treats a file the ref does not hold as changed" do
      File.write("new.rb", "x = 1\n")

      expect(changed("new.rb")).to eq(["new.rb"])
    end

    it "treats a file outside the repository as changed" do
      Dir.mktmpdir("comment-style-outside-") do |outside|
        stray = File.join(outside, "stray.rb")
        File.write(stray, "x = 1\n")

        expect(changed(stray)).to eq([stray])
      end
    end

    it "refuses a ref that names no commit" do
      expect { changed("a.rb", ref: "no-such-ref") }.to raise_error(ArgumentError, /unknown ref/)
    end
  end
end
