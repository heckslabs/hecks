require "spec_helper"

# ADR 0080, section 7: the whole command table, read from the RetiredScript rows of the Vocabulary
# chapter, where it is declared once. Every script the retired `bin/` held is a row; each row names
# the section, the aggregate and the command (or query) that replaces it, and the launcher verb that
# answers it. A row passes when the command is declared in its chapter and `hecks <verb> --help`
# answers through the launcher. Nothing here replaces the per-section specs
# (hecks_custodian_table_spec.rb, hecks_codebase_adr_rows_spec.rb, hecks_deploy_table_spec.rb),
# which check their rows in more depth.
RSpec.describe "the ADR 0080 command table, every row" do
  # One command of the table, read from the RetiredScript rows of the Vocabulary chapter, where the
  # table is declared once. `verb` is the command's snake name; every command is called by its
  # aggregate (`era.merge_tail`). Custodian and Codebase rows live in the Hecks chapter, the other
  # sections in the chapter of their own name.
  TableRow = Struct.new(:script, :section, :aggregate, :verb, keyword_init: true) do
    def chapter = %w[Custodian Codebase].include?(section) ? "Hecks" : section
    def name = verb.split("_").map(&:capitalize).join
    def qualified = "#{aggregate.gsub(/([a-z])([A-Z])/, '\1_\2').downcase}.#{verb}"
    def argv = [*(chapter == "Hecks" ? [] : [chapter.gsub(/([a-z])([A-Z])/, '\1_\2').downcase]), qualified]
    def help_name = qualified
  end

  ALL_ROWS = Hecks::Vocabulary.rows("RetiredScript").map do |row|
    TableRow.new(script: row["script"], section: row["section"], aggregate: row["aggregate"], verb: row["verb"])
  end.freeze

  # The table gives `console` and `mcp` as the launcher's names for OpenConsole and ServeMcp.
  LAUNCHER_HELP_NAME = { "open_console" => "console", "serve_mcp" => "mcp" }.freeze

  # Commands whose verb the chapter does not answer on its own: `Race` runs only as a child
  # process the ProcessPool starts, so the table gives it no launcher form.
  NOT_USER_FACING = %w[race].freeze

  before(:all) do
    @hecks = Hecks.boot(File.join(InMemoryDomain::ROOT, "lib/hecks/hecks"), install_doors: false)
    @bluebooks = Hash.new { |cache, chapter| cache[chapter] = @hecks.registry.bluebook(chapter) }
  end

  def declared?(row)
    aggregate = @bluebooks[row.chapter == "Hecks" ? "Hecks" : row.chapter].aggregate(row.aggregate)
    return false unless aggregate

    aggregate.commands.map(&:hecks_name).include?(row.name) || !aggregate.query(row.name).nil?
  end

  # A QualityControl row's help says it is that row's own command or query, so a verb another
  # aggregate also answers to (`run`) cannot pass for it.
  def names_its_own_command?(row, out)
    row.chapter != "QualityControl" || out.include?("QualityControl::#{row.aggregate}.#{row.name}")
  end

  def answers_help?(row)
    out, status = Hecks::Doors::CliRunner.call(runtime: @hecks, argv: [*row.argv, "--help"], program: "hecks")
    status.zero? && out.start_with?(LAUNCHER_HELP_NAME.fetch(row.verb, row.help_name)) && names_its_own_command?(row, out)
  end

  ALL_ROWS.each do |row|
    it "answers #{row.script} as #{row.chapter}: #{row.aggregate}.#{row.name}, `hecks #{row.argv.join(" ")}`" do
      expect(declared?(row)).to be(true), "#{row.aggregate}.#{row.name} is not declared in #{row.chapter}"
      next if NOT_USER_FACING.include?(row.verb)

      expect(answers_help?(row)).to be(true), "`hecks #{row.argv.join(" ")} --help` does not answer"
    end
  end

  it "gives every row a section the document has a table for" do
    require "hecks/tools/tools_doc"

    expect(ALL_ROWS.map(&:section).uniq - Hecks::Tools::ToolsDoc::SECTIONS).to eq([])
  end

  it "lists each command once" do
    keys = ALL_ROWS.map { |row| [row.chapter, row.aggregate, row.name, row.script] }

    expect(keys.uniq.size).to eq(keys.size)
    expect(ALL_ROWS.map(&:argv).uniq.size).to eq(ALL_ROWS.size)
  end
end
