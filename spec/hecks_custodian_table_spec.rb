require "spec_helper"

# ADR 0080, section 7: the Custodian table is complete. Each row names a script, the aggregate and
# command (or query) that replaces it, and the launcher verb that answers it; this spec lists every
# row and checks that the command or query is declared in the Hecks domain and that its verb
# answers `--help` through the launcher. Where the domain spells a row differently from the ADR,
# the row says so in `renamed`.
RSpec.describe "the Custodian rows of the ADR command table" do
  # Aggregate names differ from the table's where the table's name is a constant the gem already
  # owns (`Hecks::Fuzzing` is the fuzzing toolkit), or where one record holds a family of changes
  # (`ModelCheckRun`, `Era`).
  CustodianRow = Struct.new(:script, :aggregate, :name, :verb, :renamed, keyword_init: true)

  CUSTODIAN_LAUNCHER_NAMES = { "open_console" => "console", "serve_mcp" => "mcp" }.freeze

  CUSTODIAN_ROWS = [
    CustodianRow.new(script: "ir",                       aggregate: "Introspection", name: "Ir", verb: "ir"),
    CustodianRow.new(script: "shape",                    aggregate: "Introspection", name: "Shape",
                     verb: "shape"),
    CustodianRow.new(script: "stores", aggregate: "Introspection", name: "Stores",
                     verb: "stores"),
    CustodianRow.new(script: "history", aggregate: "Introspection", name: "History",
                     verb: "history"),
    CustodianRow.new(script: "statements", aggregate: "Introspection", name: "Statements",
                     verb: "statements"),
    CustodianRow.new(script: "narrate", aggregate: "Introspection", name: "Narrate",
                     verb: "narrate"),
    CustodianRow.new(script: "docs", aggregate: "Introspection", name: "Docs",
                     verb: "docs"),
    CustodianRow.new(script: "project_diagrams", aggregate: "Introspection", name: "ProjectDiagrams",
                     verb: "project_diagrams"),
    CustodianRow.new(script: "project_glossary", aggregate: "Introspection", name: "Glossary",
                     verb: "glossary"),
    CustodianRow.new(script: "model_check", aggregate: "ModelCheckRun", name: "ModelCheck",
                     verb: "model_check"),
    CustodianRow.new(script: "run",                      aggregate: "Operation",     name: "Run", verb: "run"),
    CustodianRow.new(script: "project",                  aggregate: "Operation",     name: "RefreshProjections",
                     verb: "refresh_projections"),
    CustodianRow.new(script: "behaviors", aggregate: "Operation", name: "RunBehaviors",
                     verb: "run_behaviors"),
    CustodianRow.new(script: "console",                  aggregate: "Operation",     name: "OpenConsole", verb: "open_console",
                     renamed: "the table's launcher spelling is `hecks console`; the verb is the command's snake name"),
    CustodianRow.new(script: "follow",                   aggregate: "Operation",     name: "Follow",
                     verb: "follow"),
    CustodianRow.new(script: "smoke_test", aggregate: "Operation", name: "SmokeTest",
                     verb: "smoke_test"),
    CustodianRow.new(script: "smoke_http", aggregate: "Operation", name: "SmokeHttp",
                     verb: "smoke_http"),
    CustodianRow.new(script: "check_era", aggregate: "Host", name: "CheckEra",
                     verb: "check_era"),
    CustodianRow.new(script: "merge_tail", aggregate: "Era", name: "MergeTail",
                     verb: "merge_tail"),
    CustodianRow.new(script: "reattest_era", aggregate: "Era", name: "Reattest",
                     verb: "reattest"),
    CustodianRow.new(script: "backfill_era_projections", aggregate: "Era", name: "BackfillProjections",
                     verb: "backfill_projections"),
    CustodianRow.new(script: "scaffold_translation", aggregate: "Era", name: "ScaffoldTranslation",
                     verb: "scaffold_translation"),
    CustodianRow.new(script: "translation_audit", aggregate: "Era", name: "AuditTranslation",
                     verb: "audit_translation"),
    CustodianRow.new(script: "translation_audit", aggregate: "Era", name: "ApproveTranslation",
                     verb: "approve_translation"),
    CustodianRow.new(script: "compact", aggregate: "Era", name: "Compact",
                     verb: "compact"),
    CustodianRow.new(script: "heki_compact", aggregate: "Era", name: "CompactHeki",
                     verb: "compact_heki"),
    CustodianRow.new(script: "(new)", aggregate: "Era", name: "HoldFirst",
                     verb: "hold_first"),
    CustodianRow.new(script: "vendor_bluebook", aggregate: "Package", name: "Vendor",
                     verb: "vendor"),
    CustodianRow.new(script: "project_cli", aggregate: "Door", name: "ProjectCli",
                     verb: "project_cli"),
    CustodianRow.new(script: "hecks_mcp_door",           aggregate: "Door",          name: "ServeMcp", verb: "serve_mcp",
                     renamed: "the table's launcher spelling is `hecks mcp`, the name exe/hecks ships; it stays " \
                              "with that router until the launcher is generated"),
    CustodianRow.new(script: "project_rust",             aggregate: "Build",         name: "ProjectRust",
                     verb: "project_rust"),
    CustodianRow.new(script: "project_wasm", aggregate: "Build", name: "BuildWasm",
                     verb: "build_wasm"),
    CustodianRow.new(script: "project_wasm_browser", aggregate: "Build", name: "BuildBrowserWasm",
                     verb: "build_browser_wasm"),
    CustodianRow.new(script: "rust_coverage", aggregate: "Build", name: "RustCoverage",
                     verb: "rust_coverage"),
    CustodianRow.new(script: "rust_coverage", aggregate: "Build", name: "CheckCoverageAllowlist",
                     verb: "check_coverage_allowlist"),
    CustodianRow.new(script: "rust_conformance", aggregate: "Build", name: "CheckConformance",
                     verb: "check_conformance"),
    CustodianRow.new(script: "rust_conformance_fuzz", aggregate: "Build", name: "FuzzConformance",
                     verb: "fuzz_conformance"),
    CustodianRow.new(script: "fuzz", aggregate: "FuzzRun",       name: "Fuzz", verb: "fuzz",
                     renamed: "the table's aggregate is Fuzzing; `Hecks::Fuzzing` is the toolkit's own module, so " \
                              "the record is named for the run, as ModelCheckRun is"),
    CustodianRow.new(script: "generate", aggregate: "FuzzRun", name: "GenerateSequence", verb: "generate_sequence",
                     renamed: "the aggregate is FuzzRun, as for fuzz"),
    CustodianRow.new(script: "bench", aggregate: "FuzzRun", name: "Bench", verb: "bench",
                     renamed: "the aggregate is FuzzRun, as for fuzz")
  ].freeze

  before(:all) do
    @hecks = Hecks.boot(File.join(InMemoryDomain::ROOT, "lib/hecks/hecks"), install_doors: false)
    @bluebook = @hecks.registry.bluebook("Hecks")
  end

  def declared?(row)
    aggregate = @bluebook.aggregate(row.aggregate)
    return false unless aggregate

    !aggregate.query(row.name).nil? || aggregate.commands.map(&:hecks_name).include?(row.name)
  end

  CUSTODIAN_ROWS.each do |row|
    it "answers #{row.script} as #{row.aggregate}.#{row.name}, `hecks #{row.verb}`" do
      expect(declared?(row)).to be(true), "#{row.aggregate}.#{row.name} is not declared in the Hecks domain"

      out, status = Hecks::Doors::CliRunner.call(runtime: @hecks, argv: [row.verb, "--help"], program: "hecks")

      expect(status).to eq(0)
      # The help names the command as the launcher lists it (hecks.world `names`).
      expect(out).to start_with(CUSTODIAN_LAUNCHER_NAMES.fetch(row.verb, row.verb))
    end
  end

  it "lists every script of the Custodian table once per command, with a reason for each rename" do
    expect(CUSTODIAN_ROWS.map { |row| [row.aggregate, row.name] }.uniq.size).to eq(CUSTODIAN_ROWS.size)
    expect(CUSTODIAN_ROWS.select(&:renamed).map(&:renamed)).to all(be_a(String))
    expect(CUSTODIAN_ROWS.map(&:verb).uniq.size).to eq(CUSTODIAN_ROWS.size)
  end

  it "gives every Custodian aggregate at least one row" do
    custodian = %w[Introspection ModelCheckRun Operation Host Era Package Door Build FuzzRun]

    expect(custodian - CUSTODIAN_ROWS.map(&:aggregate)).to be_empty
    expect(CUSTODIAN_ROWS.map(&:aggregate) - custodian).to be_empty
  end
end
