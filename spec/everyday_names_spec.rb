require "spec_helper"
require "open3"

# ADR 0163 step 49: every name in the launcher's `everyday` setting must show as a row of the help's
# everyday section. A name that does not resolve, names a query-only spelling the section does not
# take, is internal, or is not listed for people is left out of the section silently; this check
# names each one instead.
module EverydayNames
  ROOT = File.expand_path("..", __dir__)
  WORLD = File.join(ROOT, "lib/hecks/hecks/hecks.world")

  module_function

  # The names of the world's `everyday` setting, in order, read at run time.
  def names(world = File.read(WORLD))
    body = world[/everyday: %w\[(.*?)\]/m, 1]
    body.to_s.split
  end

  # The everyday section of the launcher's help, or an empty string when it is absent.
  def section(help)
    help[/^everyday:\n(.*?)\n\n/m, 1].to_s
  end

  # A launcher spelling and a row's spelling compared by their letters and digits only, so
  # `test_suite_run.run_changed` matches `TestSuiteRun.run_changed!`.
  def key(text)
    text.downcase.gsub(/[^a-z0-9]/, "")
  end

  # The names the help's section does not show, in the setting's order.
  def missing(names, help)
    rows = section(help).lines.map { |line| key(line.split.first.to_s) }
    names.reject { |name| rows.include?(key(name)) }
  end

  # The launcher's full help, as a person sees it in this checkout.
  def help
    out, = Open3.capture2e(File.join(ROOT, "exe/hecks"), chdir: ROOT)
    out
  end
end

RSpec.describe "the everyday names" do
  it "are all shown in the everyday section of the launcher's help", :aggregate_failures do
    missing = EverydayNames.missing(EverydayNames.names, EverydayNames.help)
    expect(missing).to eq([]), "not shown in everyday: #{missing.join(", ")}"
  end

  it "name at least one command, so the section is not empty" do
    expect(EverydayNames.names).not_to be_empty
  end

  it "report a name the section does not show, by its spelling" do
    help = "everyday:\n  Operation.run!   Dispatch\n\ncommands:\n"
    expect(EverydayNames.missing(%w[operation.run no.such], help)).to eq(%w[no.such])
  end

  it "read the setting out of a world, whatever else it declares" do
    world = %(launcher "X", everyday: %w[a.b\n  c.d], newcomer: %w[e.f])
    expect(EverydayNames.names(world)).to eq(%w[a.b c.d])
  end
end
