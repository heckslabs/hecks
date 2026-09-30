require "spec_helper"
require "tmpdir"

# The Make port's adapter reads generated Makefiles as text and reports the recipes that hide a
# failure (ADR 0080, section 7). It never runs `make`.
RSpec.describe Hecks::Adapters::Make do
  subject(:make) { described_class.new }

  def makefile(dir, text)
    File.join(dir, "Makefile").tap { |path| File.write(path, text) }
  end

  it "answers that a clean Makefile holds no violation" do
    Dir.mktmpdir do |dir|
      path = makefile(dir, "deploy:\n\t@echo deploying\n\taws cloudformation deploy --stack-name x\n")

      expect(make.check(makefiles: { value: path })).to eq(report: { value: "no violations found" })
    end
  end

  it "refuses with every violation a Makefile holds, by rule and line" do
    Dir.mktmpdir do |dir|
      path = makefile(dir, "mint-era:\n\t@aws cloudformation describe-stacks --stack-name x >/dev/null; \\\n\texit 0\n")

      expect { make.check(makefiles: { value: path }) }
        .to raise_error(RuntimeError, /violation\(s\) found:.*\[UNVERIFIED_EXIT_ZERO\] target "mint-era"/m)
    end
  end

  it "reads several Makefiles named together, comma separated" do
    Dir.mktmpdir do |dir|
      clean = makefile(dir, "build:\n\t@echo building\n")
      other = File.join(dir, "Other")
      File.write(other, "deploy:\n\t@echo deploying\n")

      expect(make.check(makefiles: { value: "#{clean}, #{other}" })).to eq(report: { value: "no violations found" })
    end
  end

  it "refuses a Makefile that is not there" do
    expect { make.check(makefiles: { value: "/nowhere/Makefile" }) }
      .to raise_error(RuntimeError, %r{no such file /nowhere/Makefile})
  end

  it "lints the generated fixture domains when no Makefile is named" do
    expect(make.check(makefiles: nil)).to eq(report: { value: "no violations found" })
  end
end
