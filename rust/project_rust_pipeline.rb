require "json"
require "fileutils"
require "open3"
require "tmpdir"

# STAGE 8 (`/Users/christopheryoung/.claude/plans/sequential-petting-whale.md`)
# — the OPT-IN, all-Rust equivalent of `bin/project_rust`'s own default
# body: `hecks-parse resolve`/`hecks-parse chapter` for parsing,
# `hecks-codegen full` for codegen (aggregate files + registry.rs +
# mod.rs + merged.rs, per chapter), zero `Kernel.load` of any DOMAIN
# bluebook anywhere in this file. Selected ONLY when BOTH
# `HECKS_PARSER=rust` and `HECKS_CODEGEN=rust` are set — see
# `bin/project_rust`'s own header on why the two are paired rather than
# independently toggleable, and why this is opt-in rather than the new
# default (a deliberate, documented DEVIATION from the plan's own Stage
# 8 text: other concurrent sessions in this repo call `bin/project_rust`
# for unrelated work today, and flipping its default risks silently
# breaking them the moment anything about this new path is even
# slightly off in a case the corpus doesn't cover yet).
#
# WHAT THIS FILE IS ALLOWED TO DO IN PLAIN RUBY, and why none of it
# violates "zero Kernel.load of any domain bluebook": reading a file's
# own `Hecks.bluebook "Name"` header line via `File.foreach` + regex
# (`header_chapter_name`, below) is TEXT SCANNING, not DSL execution —
# the exact same technique `spec/parser_parity_spec.rb`'s own
# `chapter_name_of` already uses, established precedent in this repo,
# not a shortcut invented here. Calling `Hecksagain::Framework.members`
# is a plain `Dir.glob` + naming lookup (`lib/hecksagain/framework.rb`'s
# own body) — no `Kernel.load` of anything. Reading
# `Hecksagain::Bluebook::MetaValidator::GRAMMAR_FILES` is a constant
# array literal. NONE of these boot, `instance_eval`, or otherwise
# execute a `.bluebook`/`.hecksagon` file's own DSL body — that only
# ever happens inside `hecks-parse`, a separate OS process, in Rust.
#
# THE `lineage` KEY, closed (was a named, deliberate gap; fixed below).
# The DEFAULT path's own `ir.json` sidecar carries a
# `lineage.capable_aggregates` list (`bin/project_rust`'s own
# `target_ir[:lineage] = ... Exporter.lineage(target_registry,
# target_domain_name)`), used ONLY by
# `rust/host/src/ir.rs::lineage_capable_aggregates` at RUNTIME (which
# aggregates get read/written through the era-partitioned lineage
# journal instead of the plain in-memory Store). `Exporter.lineage`
# itself (read it) needs exactly ONE fact per aggregate: which adapter
# NAME its sole authoritative `persisted_by` bind names
# (`Ports::Persistence::BindingPolicy.resolve`) — not the FULL open
# adapter-bind vocabulary (`deployed_to`, `uses_framework`, `role:`
# variants, `projected_by`, settings blocks). `derive_lineage`, below,
# gets that one fact the SAME way `header_chapter_name` already gets a
# chapter name — PLAIN TEXT SCANNING for one specific, narrow shape
# (`<Ns>::<Aggregate>.persisted_by("Adapter")`, no `role:`), never
# `Kernel.load`ing or interpreting the `.hecksagon` DSL as a whole. This
# does NOT reopen ADR 0023's own permanent open-vocabulary escape for
# `.hecksagon` adapter binds in the PARSER (`parse::hecksagon` still
# shape-matches and drops everything, unchanged) — it's a second, small,
# independent text scan living in THIS orchestration layer, the same
# tier `derive_append_optionals` already occupies, feeding one narrow,
# specific fact into a sidecar that needs it. Which adapters actually
# ARE lineage-capable is read the same way, off
# `lib/hecksagain/adapters/driven/*.rb`'s own `lineage_capable?`
# declarations — never hand-listed, so a second capable adapter needs no
# change here.
#
# ALSO NOT WRITTEN — `manifest.json` (the coverage manifest
# `bin/rust_coverage` reads): bookkeeping ABOUT `domain_generator.rb`'s
# own per-construct skip decisions, with "no bearing on whether the
# generated `.rs` source is correct" per that file's own header.
# Porting its ~15 call sites' worth of skip-reason tracking into
# `rust/codegen` would duplicate logic `commands.rs`/`queries.rs`/
# `read_models.rs`/etc. already compute for the REAL decision (whether
# to generate at all), not add new correctness coverage — judged
# legitimately Ruby-only debt for this stage, not silently skipped (see
# the stderr note `call` prints below, and `hecks-codegen full`'s own
# header in rust/codegen/src/main.rs).
module RustProjectPipeline
  ROOT = File.expand_path("..", __dir__).freeze
  PARSER_DIR = File.join(ROOT, "rust/parser").freeze
  CODEGEN_DIR = File.join(ROOT, "rust/codegen").freeze
  PARSER_BIN = File.join(PARSER_DIR, "target/debug/hecks-parse").freeze
  CODEGEN_BIN = File.join(CODEGEN_DIR, "target/debug/hecks-codegen").freeze

  module_function

  def call(domain)
    ensure_binaries_built!

    target_mod_name = File.basename(domain)
    bluebook_path = File.join(domain, "bluebook", "#{target_mod_name}.bluebook")
    hecksagon_path = File.join(domain, "bluebook", "#{target_mod_name}.hecksagon")
    hecksagon_path = nil unless File.exist?(hecksagon_path)

    target_chapter_name = header_chapter_name(bluebook_path)

    uses_framework_names =
      if hecksagon_path
        resolved = run_capture!(PARSER_BIN, "resolve", "--chapter", target_chapter_name, hecksagon_path)
        JSON.parse(resolved).fetch("uses_framework")
      else
        []
      end

    target_files = [bluebook_path, hecksagon_path].compact
    target_ir_text = derive_append_optionals(run_capture!(PARSER_BIN, "chapter", "--chapter", target_chapter_name, *target_files))
    # ONLY the target — the DEFAULT path's own `target_ir[:lineage] = ...`
    # (bin/project_rust) never sets this on a framework chapter's own
    # sidecar either; confirmed no lineage difference on identity/
    # governance's own ir.json when this pipeline was first verified.
    target_ir_text = derive_lineage(target_ir_text, hecksagon_path)

    # EVERY OTHER CHAPTER `uses_framework` NAMES — same real chapters
    # `bin/project_rust`'s own default path pulls in via
    # `Framework.load!`'s side effect, resolved here through the SAME
    # `Hecksagain::Framework.members` lookup that method itself calls,
    # never re-derived by hand. A framework member has no `.hecksagon`
    # of its own (`Framework.load!`'s own header) — just its `.bluebook`.
    chapters = uses_framework_names.map do |fw_name|
      fw_path = Hecksagain::Framework.members.fetch(fw_name) do
        abort "bin/project_rust (Rust path): uses_framework #{fw_name.inspect} names no known framework member — known: #{Hecksagain::Framework.members.keys.sort.join(', ')}"
      end
      fw_chapter_name = header_chapter_name(fw_path)
      unless fw_chapter_name == fw_name
        abort "bin/project_rust (Rust path): #{fw_path} declares chapter #{fw_chapter_name.inspect}, but uses_framework named #{fw_name.inspect}"
      end
      fw_ir_text = derive_append_optionals(run_capture!(PARSER_BIN, "chapter", "--chapter", fw_chapter_name, fw_path))
      {
        mod_name: fw_name.downcase,
        source_label: "#{domain} (uses_framework #{fw_name.inspect})",
        ir_text: fw_ir_text,
      }
    end

    # THE SELF-HOSTED LANGUAGE, COMPILED IN TOO — same nine files, same
    # declared order, same "Bluebook" chapter name `bin/project_rust`'s
    # own default path reads off `MetaValidator.grammar_registry`
    # (real Ruby boot there; here it's the SAME constant array of file
    # PATHS, read without booting anything).
    meta_files = Hecksagain::Bluebook::MetaValidator::GRAMMAR_FILES
    meta_ir_text = derive_append_optionals(run_capture!(PARSER_BIN, "chapter", "--chapter", "Bluebook", *meta_files))

    out_root = File.expand_path("../rust/src/generated", __dir__)
    FileUtils.mkdir_p(out_root)
    # SCOPED clearing — identical reasoning to the default path's own
    # (rust/project_rust's own comment, unchanged there): multiple
    # domains coexist on disk, so only THIS run's own directories are
    # wiped first.
    FileUtils.rm_rf(File.join(out_root, "meta"))
    FileUtils.rm_rf(File.join(out_root, "active"))
    FileUtils.rm_rf(File.join(out_root, target_mod_name))
    chapters.each { |c| FileUtils.rm_rf(File.join(out_root, c[:mod_name])) }

    Dir.mktmpdir("hecks-codegen-full") do |tmp|
      meta_ir_path = File.join(tmp, "meta_ir.json")
      File.write(meta_ir_path, meta_ir_text)
      meta_source_label = "the self-hosted language (lib/hecksagain/language/bluebook)"
      run!(CODEGEN_BIN, "full", out_root, "meta", meta_source_label, meta_ir_path)
      write_sidecars!(File.join(out_root, "meta"), meta_ir_text, meta_source_label)

      target_ir_path = File.join(tmp, "target_ir.json")
      File.write(target_ir_path, target_ir_text)

      codegen_args = [out_root, target_mod_name, domain, target_ir_path]
      chapters.each_with_index do |c, i|
        ir_path = File.join(tmp, "chapter_#{i}_ir.json")
        File.write(ir_path, c[:ir_text])
        codegen_args.concat([c[:mod_name], c[:source_label], ir_path])
      end
      run!(CODEGEN_BIN, "full", *codegen_args)
    end

    write_sidecars!(File.join(out_root, target_mod_name), target_ir_text, domain)
    chapters.each { |c| write_sidecars!(File.join(out_root, c[:mod_name]), c[:ir_text], c[:source_label]) }

    warn "bin/project_rust (Rust path): manifest.json NOT written for any directory above — " \
         "coverage bookkeeping only, no bearing on whether the generated .rs source is correct " \
         "(rust/codegen/src/main.rs's own `run_full` header has the full reasoning)."

    sync_mod_and_cargo!(out_root, target_mod_name)
  end

  # `RustProjection::Projector.mark_append_optional_fields!` — a REAL,
  # necessary derivation `rust/codegen` deliberately did NOT port
  # (`mutations.rs`'s own header, `spec/codegen_parity_spec.rb`'s own
  # header: "every real corpus field that pass would touch already
  # declares `optional: true` directly ... so the mutating pass is a
  # no-op"). That claim is true ONLY inside that spec's own comparison —
  # it builds its `ir.json` fixture by calling Ruby's
  # `DomainGenerator.call` FIRST (which mutates the `ir` Hash it was
  # handed IN PLACE) and only THEN serializes that SAME, now-mutated
  # Hash to the `ir.json` it feeds `hecks-codegen` — so the spec never
  # actually exercises `hecks-codegen` against genuinely pre-derivation
  # input. THIS pipeline does, for real (`hecks-parse`'s own `ir.json`
  # has never been touched by anything Ruby): confirmed live, the
  # self-hosted grammar's own META chapter (a real `append` mutation fed
  # by a caller-omittable command argument) DOES need this derivation —
  # several `.rs` files differed from the default path's own output
  # before this method was added. Applying the EXISTING, already-tested
  # Ruby function to the ALREADY-PARSED JSON (never re-booting or
  # re-interpreting any `.bluebook`/`.hecksagon` DSL — this is a plain
  # data transform over a Hash, the same `RustProjection::Projector`
  # code `rust/project/domain_generator.rb` itself already calls) closes
  # the gap without needing a mutation API inside `rust/codegen`'s own
  # read-only `Json` type (`json.rs`'s own header on why that's a
  # bigger, separate change).
  def derive_append_optionals(ir_text)
    ir = JSON.parse(ir_text, symbolize_names: true)
    ir[:aggregates].each do |aggregate|
      value_objects_by_name = aggregate[:value_objects].to_h { |vo| [vo[:name], vo] }
      RustProjection::Projector.mark_append_optional_fields!(aggregate, value_objects_by_name)
    end
    JSON.pretty_generate(ir)
  end

  # `Exporter.lineage`'s own Rust-path equivalent — same output shape
  # (`{capable_aggregates: [{name:, storage_name:}]}`), same underlying
  # question (`Runtime::EraCheck.adapter_for` + `.lineage_capable?`), but
  # answered from TEXT rather than a live `Runtime::Registry` boot: which
  # adapter each aggregate's own sole `persisted_by` bind names, checked
  # against which adapters actually declare `lineage_capable? = true`.
  # `nil` hecksagon (no `.hecksagon` file at all) means every aggregate is
  # unbound — `BindingPolicy.default_binding`'s own "Memory" answer, never
  # lineage-capable, so `capable_aggregates` is simply empty; matches the
  # DEFAULT path's own behavior for a hecksagon-less domain without this
  # file needing to special-case it.
  def derive_lineage(ir_text, hecksagon_path)
    ir = JSON.parse(ir_text, symbolize_names: true)
    binds = hecksagon_path ? persistence_binds(hecksagon_path) : {}
    capable_adapters = lineage_capable_adapter_names

    capable = ir[:aggregates].select do |aggregate|
      adapter_name = binds.fetch(aggregate[:name], "Memory")
      capable_adapters.include?(adapter_name)
    end

    ir[:lineage] = {
      capable_aggregates: capable.map { |aggregate| { name: aggregate[:name], storage_name: Hecksagain::Naming.snake(aggregate[:name]) } }
    }
    JSON.pretty_generate(ir)
  end

  # PLAIN TEXT SCANNING — the same technique `header_chapter_name` already
  # uses, narrowed to ONE specific shape: `<Ns>::<Aggregate>.persisted_by
  # ("Adapter")`, the ONLY bind `BindingPolicy.resolve` treats as
  # AUTHORITATIVE (`bind.role.nil? || bind.role.empty?` — `binding_proxy.rb`'s
  # own `method_missing` is what actually builds a `role:` bind, and every
  # real corpus `persisted_by` call is role-less, so excluding any line
  # that also carries `role:` is enough to stay faithful to "sole
  # authoritative bind" without a real Ruby parse). `Naming.demodulise`'s
  # own job (`Bind#aggregate_name`, `hexagon.rb`) — stripping everything
  # up to the LAST `::` — is exactly what this regex's own `(\w+)` right
  # before `.persisted_by` already captures, so no separate demodulise
  # step is needed here.
  def persistence_binds(hecksagon_path)
    text = File.read(hecksagon_path)
    binds = {}
    text.each_line do |line|
      next if line =~ /\brole:/
      next unless line =~ /(?:\w+(?:::\w+)*::)?(\w+)\.persisted_by\(\s*"([^"]+)"/

      binds[Regexp.last_match(1)] = Regexp.last_match(2)
    end
    binds
  end

  # Which adapters actually carry eras — read off their own source, the
  # same "structural fact about a file, not domain DSL execution"
  # precedent `header_chapter_name`/`Hecksagain::Framework.members`
  # already establish, so a second lineage-capable adapter arriving needs
  # no change here (matches `EraCheck.lineage_capable?`'s own "the
  # capability is asked of the adapter, never of its name" design).
  def lineage_capable_adapter_names
    Dir[File.join(ROOT, "lib/hecksagain/adapters/driven/*.rb")].filter_map do |path|
      text = File.read(path)
      next unless text.match?(/lineage_capable\?\s*=\s*true/)

      text[/^\s*class\s+(\w+)/, 1]
    end.compact
  end

  # The declared chapter name off a `.bluebook` file's own header line —
  # PLAIN TEXT SCANNING, the same technique
  # `spec/parser_parity_spec.rb::chapter_name_of` already uses (this
  # file's own header explains why that's not "booting a domain").
  def header_chapter_name(path)
    line = File.foreach(path).find { |l| l =~ /\A\s*Hecks\.bluebook\s+"([^"]+)"/ }
    (line && Regexp.last_match(1)) or abort "bin/project_rust (Rust path): #{path} has no 'Hecks.bluebook \"Name\"' header"
  end

  # `ir.json` (the EXACT bytes `hecks-parse chapter` already emitted —
  # never re-serialized) and `metadata.rs` (the SAME `pub const IR_JSON:
  # &str = ...;` shape `domain_generator.rb` writes, built with Ruby's
  # own `String#inspect` against that same exact text — byte-identical
  # to the default path's own metadata.rs for any domain whose ir.json
  # doesn't carry a `lineage` key difference, see this file's own
  # header). Deliberately NOT built inside `hecks-codegen` — re-parsing
  # and re-pretty-printing JSON there would risk a NON-byte-exact
  # reformat for no reason, when the exact bytes this pipeline already
  # captured from `hecks-parse` are sitting right here.
  def write_sidecars!(mod_dir, ir_text, source_label)
    FileUtils.mkdir_p(mod_dir)

    ir_json_path = File.join(mod_dir, "ir.json")
    File.write(ir_json_path, ir_text)
    puts "wrote #{ir_json_path}"

    metadata_path = File.join(mod_dir, "metadata.rs")
    File.open(metadata_path, "w") do |f|
      f.puts "// GENERATED by bin/project_rust — #{source_label}'s own canonical IR,"
      f.puts "// embedded for runtime self-description. Not read by any dispatch"
      f.puts "// function in this module — introspection only."
      f.puts "pub const IR_JSON: &str = #{ir_text.inspect};"
    end
    puts "wrote #{metadata_path}"
  end

  def ensure_binaries_built!
    build!(PARSER_DIR)
    build!(CODEGEN_DIR)
  end

  def build!(crate_dir)
    ok = system("cargo", "build", chdir: crate_dir, out: $stdout, err: $stderr)
    ok or abort "bin/project_rust (Rust path): cargo build failed in #{crate_dir} — run it there directly to see why"
  end

  def run_capture!(*cmd)
    out, err, status = Open3.capture3(*cmd)
    status.success? or abort "bin/project_rust (Rust path): #{cmd.join(' ')} failed:\n#{err}"
    out
  end

  def run!(*cmd)
    ok = system(*cmd)
    ok or abort "bin/project_rust (Rust path): #{cmd.join(' ')} failed"
  end

  # IDENTICAL BOOKKEEPING to `bin/project_rust`'s own default-path tail
  # (root `mod.rs` + `Cargo.toml` feature sync) — deliberately
  # DUPLICATED here rather than extracted into a shared method: the
  # default path's own body must stay provably byte-for-byte untouched
  # by this stage (see this stage's own verification requirements), so
  # this is a faithful re-implementation of that tail for the opt-in
  # path, not a refactor of the original.
  def sync_mod_and_cargo!(out_root, target_mod_name)
    all_dirs = Dir.children(out_root).select { |name| File.directory?(File.join(out_root, name)) }.sort
    domains = all_dirs.select { |name| File.exist?(File.join(out_root, name, "merged.rs")) }

    root_mod_path = File.join(out_root, "mod.rs")
    File.open(root_mod_path, "w") do |f|
      f.puts "// GENERATED by bin/project_rust — re-run it to refresh this list."
      f.puts "pub mod meta;"
      (all_dirs - ["meta"]).each { |name| f.puts "pub mod #{name};" }
      f.puts
      f.puts "// `active` is whichever ONE domain's own merged Store/dispatch table"
      f.puts "// is selected by Cargo feature (rust/Cargo.toml, kept in sync with this"
      f.puts "// list by bin/project_rust) — kernel/cli.rs imports"
      f.puts "// `crate::generated::active::{dispatch_by_name, Store, ...}` unchanged"
      f.puts "// no matter which domain that resolves to."
      domains.each do |name|
        f.puts "#[cfg(feature = #{name.inspect})]"
        f.puts "pub use #{name}::merged as active;"
      end
    end
    puts "wrote #{root_mod_path}"

    cargo_toml_path = File.expand_path("../rust/Cargo.toml", __dir__)
    cargo_toml = File.read(cargo_toml_path)
    unless cargo_toml.include?("[features]")
      cargo_toml = cargo_toml.sub(/\A/, <<~TOML)
        # ONE FEATURE PER GENERATED DOMAIN — selects which domain's own
        # generated::<domain>::merged module `generated::active` re-exports
        # (rust/src/generated/mod.rs). Kept in sync by bin/project_rust: a
        # feature is added here whenever a new domain is generated, never
        # removed (the domain's own generated/<name>/ directory is the
        # source of truth for whether it still exists). `default` tracks
        # whichever domain was generated MOST RECENTLY, so a bare
        # `cargo build`/`cargo test` keeps behaving exactly as it always
        # has; any other still-generated domain stays reachable via
        # `--no-default-features --features <name>`.
        [features]
        default = []

      TOML
    end
    domains.each do |name|
      next if cargo_toml =~ /^#{Regexp.escape(name)}\s*=/
      cargo_toml = cargo_toml.sub(/^default\s*=.*$/) { "#{Regexp.last_match(0)}\n#{name} = []" }
    end
    cargo_toml = cargo_toml.sub(/^default\s*=.*$/, "default = [#{target_mod_name.inspect}]")
    File.write(cargo_toml_path, cargo_toml)
    puts "wrote #{cargo_toml_path} (default feature: #{target_mod_name})"
  end
end
