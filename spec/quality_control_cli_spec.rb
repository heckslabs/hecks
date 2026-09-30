require "spec_helper"
require "stringio"
require "tmpdir"
require "hecks/quality_control/cli/child"
require "hecks/quality_control/cli/qa_sweep"
require "hecks/quality_control/cli/qa_generated_domains"
require "hecks/quality_control/cli/qa_tick"
require "hecks/quality_control/cli/qa_log_bug"
require "hecks/quality_control/cli/qa_open_pr"
require "hecks/quality_control/cli/qa_pr_check"
require "hecks/quality_control/cli/qa_postgres_migrate"
require "hecks/quality_control/cli/qa_postgres_role"
require "hecks/quality_control/cli/qa_concurrency_racer"

# The bodies of the former `qa_*` scripts live in `Hecks::QualityControlCli`; each takes its argv
# and the repository root and returns the exit status the script ends with. What needs the ledger's
# Postgres is proven by the `:io` specs that run the scripts; these cover what does not.
RSpec.describe Hecks::QualityControlCli do
  let(:root) { InMemoryDomain::ROOT }

  def expect_abort(message, &block)
    expect { expect(&block).to raise_error(SystemExit) { |error| expect(error.status).to eq(1) } }
      .to output(message).to_stderr
  end

  describe Hecks::QualityControlCli::Child do
    it "starts a command from lib/ under Bundler, its arguments after `--`" do
      argv = described_class.argv("/repo", "qa_sweep", "--all", "--seeds", "2")

      expect(argv.first(3)).to eq(%w[bundle exec ruby])
      expect(argv).to include("-I", "/repo/lib")
      expect(argv[(argv.index("--") + 1)..]).to eq(%w[--all --seeds 2])
      expect(argv[argv.index("-e") + 1]).to include('require "hecks/quality_control/cli/qa_sweep"', "QaSweep.call")
    end

    it "names a class and file that exist for every command" do
      described_class::COMMANDS.each do |command, (klass, _style)|
        expect(File).to exist(File.join(root, "lib/hecks/quality_control/cli/#{command}.rb")), command
        require "hecks/quality_control/cli/#{command}"
        expect(Hecks::QualityControlCli.const_defined?(klass)).to be(true), command
      end
    end

    it "refuses a command it does not know" do
      expect { described_class.argv("/repo", "qa_nothing") }.to raise_error(KeyError)
    end
  end

  describe Hecks::QualityControlCli::QaSweep do
    def sweep(*argv) = described_class.call(argv, root: root)

    it "prints its usage for --help" do
      expect { expect(sweep("--help")).to eq(0) }.to output(/\Ausage: hecks quality_control ask run/).to_stdout
    end

    it "refuses a seed count below one before it boots anything" do
      expect_abort(/--seeds must be at least 1/) { sweep("banking", "--seeds", "0") }
    end

    it "refuses a second target, --all with a target, and a fraction outside 0..1" do
      expect_abort(/target already given: "banking"/) { sweep("banking", "pizzas") }
      expect_abort(/--all sweeps every waiting target itself/) { sweep("--all", "banking") }
      expect_abort(/--adversarial must be between 0 and 1, got 2/) { sweep("--adversarial", "2") }
    end

    it "refuses modes it does not know, and a release without notes or a target" do
      expect_abort(/--modes names no such mode: warp/) { sweep("--modes", "warp") }
      expect_abort(/--release needs an explicit target-reference/) { sweep("--release") }
      expect_abort(/--release needs --notes/) { sweep("banking", "--release") }
      expect_abort(/--notes only means something with --release/) { sweep("banking", "--notes", "x") }
    end

    it "needs a target for --persistence-parity, since it never auto-picks" do
      expect_abort(/--persistence-parity needs an explicit target-reference/) { sweep("--persistence-parity") }
    end
  end

  describe Hecks::QualityControlCli::QaTick do
    let(:tick) { described_class.new(root: root) }

    it "prints its usage for --help and refuses arguments" do
      expect { expect(tick.call(["--help"])).to eq(0) }.to output("usage: hecks quality_control tick\n").to_stdout
      expect_abort(/this script takes no arguments/) { tick.call(["now"]) }
    end

    it "collapses runs of held-seed lines outside a finding, and counts them" do
      raw = "sweeping x\n  seed 1: held (ruby_only)\n  seed 2: held (ruby_only)\nclean\n"

      condensed = tick.send(:condense_sweep_output, raw)

      expect(condensed).to include("(2 held seed(s) suppressed here")
      expect(condensed).not_to include("seed 1: held")
    end

    it "copies a FOUND SOMETHING block verbatim, held lines inside it included" do
      raw = "  seed 1: held (ruby_only)\nFOUND SOMETHING (1) — act\n  seed 2: held (ruby_only)\nbody\n"

      condensed = tick.send(:condense_sweep_output, raw)

      expect(condensed).to include("FOUND SOMETHING (1) — act\n  seed 2: held (ruby_only)\nbody\n")
      expect(condensed).not_to include("seed 1: held")
    end

    it "leaves QA_SWEEP_TRACE output to the log, naming that it did" do
      raw = "FOUND SOMETHING (1)\nbody\nQA_SWEEP_TRACE output (by target)\n  x\n"

      condensed = tick.send(:condense_sweep_output, raw)

      expect(condensed).to include("body").and include("output omitted here")
      expect(condensed).not_to include("  x\n")
    end

    it "re-execs on macOS through Child.argv, since $PROGRAM_NAME of a `ruby -e` child is not a script" do
      stub_const("RUBY_PLATFORM", "arm64-darwin23")
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("OBJC_DISABLE_INITIALIZE_FORK_SAFETY").and_return(nil)
      allow(ENV).to receive(:[]=)
      expect(tick).to receive(:exec).with(*Hecks::QualityControlCli::Child.argv(root, "qa_tick"))

      tick.send(:reexec_with_fork_safety)
    end

    it "ends 2 if any step found something, 0 if all are clean, else 1" do
      expect(tick.send(:verdict, 0)).to eq("clean")
      expect(tick.send(:verdict, 2)).to eq("FOUND SOMETHING")
      expect(tick.send(:verdict, 1)).to eq("operational error")
      expect(tick.send(:verdict, 9)).to eq("exit 9")
    end
  end

  describe "the scripts' argument rules" do
    it "qa_log_bug refuses a missing flag, a bad triage and a bad reproduced value" do
      expect_abort(/--title is required/) do
        Hecks::QualityControlCli::QaLogBug.call(["--sweep", "s"], root: root)
      end
      full = %w[--sweep s --title t --demonstration d --symptom y --expectation e --submitter me]
      expect_abort(/--triage must be one of self_contained\|bigger, got "maybe"/) do
        Hecks::QualityControlCli::QaLogBug.call([*full, "--triage", "maybe"], root: root)
      end
      expect_abort(/--reproduced must be one of yes\|no, got "sometimes"/) do
        Hecks::QualityControlCli::QaLogBug.call([*full, "--triage", "bigger", "--reproduced", "sometimes"], root: root)
      end
    end

    it "qa_open_pr refuses a bug and an improvement together, and an angle without an improvement" do
      expect_abort(/give --bug BUG#n OR --improvement, not both/) do
        Hecks::QualityControlCli::QaOpenPr.call(%w[--bug B --improvement --title t], root: root)
      end
      expect_abort(/--angle only means something with --improvement/) do
        Hecks::QualityControlCli::QaOpenPr.call(%w[--bug B --angle A --title t], root: root)
      end
    end

    it "qa_pr_check and qa_tick print a usage line for --help, and take nothing else" do
      expect { expect(Hecks::QualityControlCli::QaPrCheck.call(["--help"], root: root)).to eq(0) }
        .to output("usage: hecks quality_control check_pull_requests\n").to_stdout
      expect_abort(/takes no arguments/) { Hecks::QualityControlCli::QaPrCheck.call(["x"], root: root) }
    end

    it "qa_postgres_role and qa_postgres_migrate answer usage errors with status 1, touching nothing" do
      err = StringIO.new

      expect(Hecks::QualityControlCli::QaPostgresRole.call([], err: err, out: StringIO.new)).to eq(1)
      expect(err.string).to include("no database named", "usage: hecks quality_control create_ledger_role")
      err = StringIO.new
      absent = Dir.mktmpdir { |scratch| File.join(scratch, "no/such") }
      expect(Hecks::QualityControlCli::QaPostgresMigrate.call([absent], err: err, out: StringIO.new)).to eq(1)
      expect(err.string).to include("no such domain directory #{absent.inspect}")
    end

    it "qa_concurrency_racer needs all five arguments" do
      expect_abort(/usage: hecks quality_control race/) { Hecks::QualityControlCli::QaConcurrencyRacer.call(%w[a b]) }
    end

    it "compares migrated states without regard to key type or hash order" do
      canonical = Hecks::QualityControlCli::QaPostgresMigrate.method(:canonical)

      expect(canonical.call({ a: 1, "b" => [{ d: 1, c: 2 }] })).to eq(canonical.call({ "b" => [{ "c" => 2, "d" => 1 }],
                                                                                       "a" => 1 }))
      expect(canonical.call({ a: [1, 2] })).not_to eq(canonical.call({ a: [2, 1] }))
    end
  end
end
