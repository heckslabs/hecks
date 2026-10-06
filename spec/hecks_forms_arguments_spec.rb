require "spec_helper"
require "hecks/tools/tools_doc"

# Each `name=` a form of docs/tools.md teaches must be an argument the verb's own `--help` lists.
# The forms are rendered from the command's arguments, so this is a cross-check on the renderer: a
# form cannot name an argument the verb does not take.
RSpec.describe "the launcher forms' arguments" do
  before(:all) do
    @runtime = Hecks.boot(File.join(InMemoryDomain::ROOT, "lib/hecks/hecks"), install_doors: false)
    @forms   = Hecks::Tools::ToolsDoc.forms(root: InMemoryDomain::ROOT)
  end

  def help_for(words)
    Hecks::Doors::CliRunner.call(runtime: @runtime, argv: [*words, "--help"], program: "hecks").first
  end

  # One `hecks …` command of a form: the words that name its verb, and the arguments it names.
  def commands
    @forms.flat_map do |script, text|
      text.to_s.split(/;\s*(?=hecks )/).filter_map do |command|
        words = command.delete_prefix("hecks ").split(/\s+/)
        next if words.first.include?("|")

        verb = words.first(%w[quality_control deploy ask].include?(words.first) ? 2 : 1)
        [script, verb, command.scan(/(?<![\w-])([a-z_]+)=/).flatten.uniq]
      end
    end
  end

  # What a form names that its verb's `--help` does not list, as a message; nil when nothing.
  def unknown_argument_problem(script, verb, names)
    return if names.empty?

    help = help_for(verb)
    return if help.start_with?("no such")

    unknown = names.reject { |name| help.include?(name) }
    "#{script}: #{verb.join(" ")} has no #{unknown.join(", ")}" unless unknown.empty?
  end

  it "names only arguments its verb takes" do
    stale = commands.filter_map { |script, verb, names| unknown_argument_problem(script, verb, names) }

    expect(stale).to eq([])
  end

  it "gives smoke_http no secret, which comes from SMOKE_WEBHOOK_SECRET" do
    expect(@forms.fetch("smoke_http")).not_to include("secret")
  end
end
