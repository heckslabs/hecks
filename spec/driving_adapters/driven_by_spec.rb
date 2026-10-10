require "spec_helper"
require "tmpdir"

RSpec.describe "driven_by, the hecksagon word that admits a driving adapter" do
  def bluebook_text
    <<~'RUBY'
      Hecks.bluebook "Lending" do
        vision "Lend something and take it back."
        supporting

        aggregate "Loan" do
          description "A thing lent out."
          attribute :name, LoanName
          identified_by :name

          value_object "LoanName" do
            attribute :value, String, pattern: '[^ \t\n\r]'
            invariant("a loan is named") { !value.to_s.empty? }
          end

          command "OpenLoan" do
            goal "Lend something out"
            attribute :name, LoanName
            sets :name
            emits "LoanOpened"
          end
        end
      end
    RUBY
  end

  # Boots a one-aggregate domain whose hecksagon is `wiring`, without installing the Ruby adapter.
  def boot_with(wiring, **options)
    Dir.mktmpdir("driven-by") do |dir|
      File.write(File.join(dir, "lending.bluebook"), bluebook_text)
      File.write(File.join(dir, "lending.hecksagon"), "Hecks.hecksagon \"Lending\" do\n  Lending::Loan.persisted_by(\"Memory\")\n#{wiring}\nend\n")
      return Hecks.boot(dir, install_driving: false, **options)
    end
  end

  let(:admission) { Hecks::Adapters::Driving::Admission }

  it "is recorded on the hecksagon, each adapter once per declaration", :aggregate_failures do
    runtime = boot_with("  driven_by \"Mcp\"\n  driven_by \"Cli\"")

    expect(runtime.registry.hecksagon("Lending").driving).to eq(%w[Mcp Cli])
    expect(runtime.registry.hecksagon("Lending").driven_by?("Json")).to be false
  end

  it "leaves a domain that declares none open to every adapter" do
    registry = boot_with("").registry

    expect(Hecks::Bluebook::Hecksagon::DRIVING_ADAPTERS.map { |name| admission.refusal(registry, name) }).to all(be_nil)
  end

  it "names the domain and what it admits when an adapter is left out" do
    registry = boot_with("  driven_by \"Mcp\"").registry

    expect(admission.refusal(registry, "Cli")).to eq("Lending is not driven by Cli: its hecksagon admits only Mcp (driven_by)")
  end

  it "refuses a name no driving adapter answers to, at boot" do
    expect { boot_with("  driven_by \"Telnet\"") }.to raise_error(Hecks::Runtime::WiringError, /Telnet.*no driving adapter/)
  end

  it "makes the Ruby adapter refuse a domain that left Ruby out" do
    expect { boot_with("  driven_by \"Mcp\"", install_driving: true) }
      .to raise_error(admission::Refused, /not driven by Ruby/)
  end

  it "installs the Ruby adapter for a domain that admits it" do
    expect { boot_with("  driven_by \"Ruby\"", install_driving: true) }.not_to raise_error
  end

  it "makes the launcher answer the refusal with status 1, for help as for a command", :aggregate_failures do
    runtime = boot_with("  driven_by \"Mcp\"")
    runner  = Hecks::Adapters::Driving::CliRunner

    expect(runner.call(runtime: runtime, argv: ["loan.open_loan"])).to eq([admission.refusal(runtime.registry, "Cli"), 1])
    expect(runner.usage(runtime: runtime, argv: [])).to eq([admission.refusal(runtime.registry, "Cli"), 1])
  end

  it "makes the JSON adapter refuse to resolve an aggregate of a domain that left Json out" do
    runtime = boot_with("  driven_by \"Cli\"")

    expect { Hecks::Adapters::Driving::Json.aggregate(runtime, "Lending", "Loan") }
      .to raise_error(admission::Refused, /not driven by Json/)
  end
end
