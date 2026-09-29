# frozen_string_literal: true

require "stringio"
require "hecks/three_zero"

RSpec.describe Hecks::ThreeZero do
  let(:root) { File.expand_path("..", __dir__) }
  let(:scripts) { Dir[File.join(root, "bin/*")].map { |path| File.basename(path) }.sort }

  def terminal
    StringIO.new.tap { |io| io.define_singleton_method(:tty?) { true } }
  end

  it "names a 3.0 form for every bin/ script, and for nothing else" do
    expect(described_class::FORMS.keys.sort).to eq(scripts)
  end

  it "is announced by every bin/ script, under its own name" do
    scripts.each do |name|
      expect(File.read(File.join(root, "bin", name))).to include("Hecks::ThreeZero.notice(#{name.inspect})"), name
    end
  end

  it "tells a terminal what a script becomes" do
    io = terminal
    described_class.notice("compact", io: io, env: {})
    expect(io.string).to include("bin/compact is removed in 3.0.0").and include("hecks compact <domain>")
  end

  it "says nothing to a pipe, so piped output and CI logs stay clean" do
    io = StringIO.new
    described_class.notice("compact", io: io, env: {})
    expect(io.string).to be_empty
  end

  it "says nothing when HECKS_NO_3_0_NOTICE is set" do
    io = terminal
    described_class.notice("compact", io: io, env: { "HECKS_NO_3_0_NOTICE" => "1" })
    expect(io.string).to be_empty
  end

  it "gives an exe/hecks route its 3.0 form, through the script it runs" do
    io = terminal
    described_class.route_notice("mcp", io: io, env: {})
    expect(io.string).to include("`hecks mcp`")
  end

  it "comments a generated Makefile or script with the 3.0 form of each bin/ call, and leaves other files alone" do
    files = { "Makefile" => "deploy:\n\tbin/project_wasm x\n", "run.sh" => "#!/bin/sh\nbin/check_era a b\n",
              "template.yaml" => "bin/fuzz\n" }
    out = described_class.annotate_deploy_files(files)

    expect(out["Makefile"]).to start_with("# hecks 3.0.0 removes bin/").and include("bin/project_wasm becomes")
    expect(out["run.sh"]).to start_with("#!/bin/sh\n# hecks 3.0.0 removes bin/")
    expect(out["template.yaml"]).to eq("bin/fuzz\n")
  end
end
