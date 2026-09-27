require "json"
require "fileutils"
require "open3"
require "tmpdir"

# Opt-in, all-Rust equivalent of bin/project_rust's default path, selected
# when HECKS_PARSER=rust and HECKS_CODEGEN=rust; never boots a bluebook DSL.
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
    # Becomes a directory name, Rust module identifier, and Cargo feature
    # name below (see Projector.valid_domain_mod_name?).
    unless RustProjection::Projector.valid_domain_mod_name?(target_mod_name)
      abort "bin/project_rust (Rust path): domain name #{target_mod_name.inspect} (from #{domain.inspect}) can't be " \
            "used as-is — it has to double as a Rust module identifier and a Cargo feature name, and this one is " \
            "either not a plain lowercase identifier, is a Rust keyword, or collides with a reserved Cargo.toml " \
            "key (#{RustProjection::Projector::CARGO_RESERVED_DOMAIN_NAMES.join(', ')}). Rename the domain directory."
    end
    bluebook_paths = Dir.glob(File.join(domain, "bluebook", "*.bluebook")).sort
    abort "bin/project_rust (Rust path): #{domain} has no .bluebook files" if bluebook_paths.empty?
    hecksagon_path = File.join(domain, "bluebook", "#{target_mod_name}.hecksagon")
    hecksagon_path = nil unless File.exist?(hecksagon_path)

    target_chapter_name = header_chapter_name(bluebook_paths.first)
    target_bluebooks = bluebook_paths.select { |path| header_chapter_name(path) == target_chapter_name }

    uses_framework_names, uses_embryonaut_bluebook_names =
      if hecksagon_path
        resolved = JSON.parse(run_capture!(PARSER_BIN, "resolve", "--chapter", target_chapter_name, hecksagon_path))
        [resolved.fetch("uses_framework"), resolved.fetch("uses_embryonaut_bluebook")]
      else
        [[], []]
      end

    target_files = target_bluebooks + [hecksagon_path].compact
    target_ir_text = derive_append_optionals(run_capture!(PARSER_BIN, "chapter", "--chapter", target_chapter_name, *target_files))
    # Only the target gets a lineage sidecar — matches the default path,
    # which never sets one on a framework chapter either.
    target_ir_text = derive_lineage(target_ir_text, hecksagon_path, sibling_world_path(domain, target_mod_name))

    # Mirrors bin/project_rust's own Framework.load! resolution. A framework
    # member has no .hecksagon of its own, only its .bluebook.
    chapters = uses_framework_names.map do |fw_name|
      fw_path = Hecks::Framework.members.fetch(fw_name) do
        abort "bin/project_rust (Rust path): uses_framework #{fw_name.inspect} names no known framework member — known: #{Hecks::Framework.members.keys.sort.join(', ')}"
      end
      fw_chapter_name = header_chapter_name(fw_path)
      unless fw_chapter_name == fw_name
        abort "bin/project_rust (Rust path): #{fw_path} declares chapter #{fw_chapter_name.inspect}, but uses_framework named #{fw_name.inspect}"
      end
      fw_ir_text = derive_append_optionals(run_capture!(PARSER_BIN, "chapter", "--chapter", fw_chapter_name, fw_path))
      {
        mod_name:     fw_name.downcase,
        source_label: "#{domain} (uses_framework #{fw_name.inspect})",
        ir_text:      fw_ir_text
      }
    end

    # Mirrors EmbryonautBluebook.load!: every .bluebook file directly under
    # vendor/embryonaut_bluebooks/<name>/bluebook/, sorted. A vendored
    # package has no .hecksagon of its own either, just its .bluebook(s).
    chapters += uses_embryonaut_bluebook_names.map do |pkg_name|
      pkg_dir = File.join(domain, "vendor", "embryonaut_bluebooks", pkg_name.to_s, "bluebook")
      pkg_files = Dir.glob(File.join(pkg_dir, "*.bluebook")).sort
      if pkg_files.empty?
        abort "bin/project_rust (Rust path): uses_embryonaut_bluebook #{pkg_name.inspect} names no vendored " \
              "bluebook at #{pkg_dir} — run bin/vendor_embryonaut_bluebooks #{pkg_name}"
      end
      pkg_chapter_name = header_chapter_name(pkg_files.first)
      expected_chapter_name = Hecks::Naming.pascal(pkg_name.to_s)
      unless pkg_chapter_name == expected_chapter_name
        abort "bin/project_rust (Rust path): #{pkg_files.first} declares chapter #{pkg_chapter_name.inspect}, but " \
              "uses_embryonaut_bluebook #{pkg_name.inspect} expects #{expected_chapter_name.inspect}"
      end
      pkg_bluebooks = pkg_files.select { |path| header_chapter_name(path) == pkg_chapter_name }
      pkg_ir_text = derive_append_optionals(run_capture!(PARSER_BIN, "chapter", "--chapter", pkg_chapter_name, *pkg_bluebooks))
      {
        # Derived from the declared chapter name, not pkg_name.downcase
        # directly — the two diverge once a package name has an underscore.
        mod_name:     expected_chapter_name.downcase,
        source_label: "#{domain} (uses_embryonaut_bluebook #{pkg_name.inspect})",
        ir_text:      pkg_ir_text
      }
    end

    # Framework- and embryonaut_bluebook-derived chapters can collide on
    # mod_name (chapters here is a plain Array, not a Hash), so guard
    # explicitly against two entries overwriting each other's sidecars.
    chapters.group_by { |c| c[:mod_name] }.each_value do |group|
      next if group.size == 1

      abort "bin/project_rust (Rust path): #{group.map { |c| c[:source_label] }.join(' and ')} both resolve to the " \
            "same generated module #{group.first[:mod_name].inspect} — attach #{target_chapter_name} to at most one " \
            "of them"
    end

    # The self-hosted grammar's own "Bluebook" chapter, read without
    # booting anything.
    meta_files = Hecks::Bluebook::MetaValidator::GRAMMAR_FILES
    meta_ir_text = derive_append_optionals(run_capture!(PARSER_BIN, "chapter", "--chapter", "Bluebook", *meta_files))

    out_root = File.expand_path("../rust/src/generated", __dir__)
    FileUtils.mkdir_p(out_root)
    # Only this run's own directories are cleared — other domains coexist
    # on disk.
    FileUtils.rm_rf(File.join(out_root, "meta"))
    FileUtils.rm_rf(File.join(out_root, "active"))
    FileUtils.rm_rf(File.join(out_root, target_mod_name))
    chapters.each { |c| FileUtils.rm_rf(File.join(out_root, c[:mod_name])) }

    Dir.mktmpdir("hecks-codegen-full") do |tmp|
      meta_ir_path = File.join(tmp, "meta_ir.json")
      File.write(meta_ir_path, meta_ir_text)
      meta_source_label = "the self-hosted language (lib/hecks/language/bluebook)"
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

    sync_mod_and_cargo!(out_root, target_mod_name)
  end

  # Applies the same append-optional-field derivation domain_generator.rb
  # applies in Ruby — hecks-parse's own ir.json has not had it applied yet.
  def derive_append_optionals(ir_text)
    ir = JSON.parse(ir_text, symbolize_names: true)
    ir[:aggregates].each do |aggregate|
      value_objects_by_name = aggregate[:value_objects].to_h { |vo| [vo[:name], vo] }
      RustProjection::Projector.mark_append_optional_fields!(aggregate, value_objects_by_name)
    end
    JSON.pretty_generate(ir)
  end

  # Text-based equivalent of Exporter.lineage — no Runtime::Registry boot.
  def derive_lineage(ir_text, hecksagon_path, world_path = nil)
    ir = JSON.parse(ir_text, symbolize_names: true)
    binds = hecksagon_path ? persistence_binds(hecksagon_path) : {}
    fallback = (world_path && default_adapter_name(world_path, ir[:name])) || "Memory"
    capable_adapters = lineage_capable_adapter_names

    capable = ir[:aggregates].select do |aggregate|
      adapter_name = binds.fetch(aggregate[:name], fallback)
      capable_adapters.include?(adapter_name)
    end

    ir[:lineage] = {
      capable_aggregates: capable.map { |aggregate| { name: aggregate[:name], storage_name: Hecks::Naming.snake(aggregate[:name]) } }
    }
    JSON.pretty_generate(ir)
  end

  # Matches only role-less persisted_by binds — the sole authoritative kind.
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

  # The target's own `.world` file, if it has one — named for the domain the
  # same way its `.hecksagon` is.
  def sibling_world_path(domain, target_mod_name)
    path = File.join(domain, "bluebook", "#{target_mod_name}.world")
    path if File.exist?(path)
  end

  # A .world file may hold several worlds (one per chapter) — only lines
  # inside the target chapter's own Hecks.world block count, and the last
  # default_adapter there wins, matching the Ruby builder.
  def default_adapter_name(world_path, chapter)
    in_target_world = false
    found = nil
    File.foreach(world_path) do |line|
      if (opened = line[/\AHecks\.world[^"]*"([^"]*)"/, 1])
        in_target_world = opened == chapter
      elsif in_target_world && (name = line[/\A\s*default_adapter\s+"([^"]*)"/, 1])
        found = name
      end
    end
    found
  end

  # Read off adapter source directly, so a new lineage-capable adapter
  # needs no change here.
  def lineage_capable_adapter_names
    Dir[File.join(ROOT, "lib/hecks/adapters/driven/*.rb")].filter_map do |path|
      text = File.read(path)
      next unless text.match?(/lineage_capable\?\s*=\s*true/)

      text[/^\s*class\s+(\w+)/, 1]
    end.compact
  end

  # The declared chapter name off a .bluebook file's own header line.
  def header_chapter_name(path)
    line = File.foreach(path).find { |l| l =~ /\A\s*Hecks\.bluebook\s+"([^"]+)"/ }
    (line && Regexp.last_match(1)) or abort "bin/project_rust (Rust path): #{path} has no 'Hecks.bluebook \"Name\"' header"
  end

  # Writes ir.json byte-identical to hecks-parse's own output — never
  # reparsed or reformatted, to avoid a non-byte-exact diff for no reason.
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
      f.puts "pub const IR_JSON: &str = #{RustProjection::Projector.rust_string_literal(ir_text)};"
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

  # Duplicates bin/project_rust's own default-path tail (root mod.rs +
  # Cargo.toml feature sync) rather than extracting a shared method, so
  # the default path's own body stays byte-for-byte untouched.
  def sync_mod_and_cargo!(out_root, target_mod_name)
    all_dirs = Dir.children(out_root).select { |name| File.directory?(File.join(out_root, name)) }.sort
    domains = all_dirs.select { |name| File.exist?(File.join(out_root, name, "merged.rs")) }

    root_mod_path = File.join(out_root, "mod.rs")
    File.open(root_mod_path, "w") do |f|
      f.puts "// GENERATED by bin/project_rust — re-run it to refresh this list."
      f.puts "//"
      f.puts "// BUG#25 — every DOMAIN (an entry in `domains`, below: a directory"
      f.puts "// carrying its own merged.rs and therefore its own Cargo feature) is"
      f.puts "// declared behind that SAME feature, so a broken or absent domain's"
      f.puts "// generated code is never even compiled into a build that selects a"
      f.puts "// DIFFERENT domain — `cargo build --features waybill` used to pull in"
      f.puts "// every OTHER domain's `pub mod` unconditionally, so one domain's own"
      f.puts "// non-compiling generated code (a `has_many` field, before this fix)"
      f.puts "// broke every feature's build, not just its own. A shared FRAMEWORK"
      f.puts "// chapter (governance/identity — no merged.rs of its own, so absent"
      f.puts "// from `domains`) stays unconditional: it has no single feature of its"
      f.puts "// own to gate behind, and is compiled in by whichever domain(s) attach"
      f.puts "// it via `uses_framework`."
      all_dirs.each do |name|
        f.puts "#[cfg(feature = #{name.inspect})]" if domains.include?(name)
        f.puts "pub mod #{name};"
      end
      f.puts
      f.puts "// `active` is whichever ONE domain's own merged Store/dispatch table"
      f.puts "// is selected by Cargo feature (rust/Cargo.toml, kept in sync with this"
      f.puts "// list by bin/project_rust) — kernel/cli.rs imports"
      f.puts "// `crate::generated::active::{dispatch_by_name, Store, ...}` unchanged"
      f.puts "// no matter which domain that resolves to."
      f.puts "//"
      f.puts "// DOMAIN FEATURES ARE MUTUALLY EXCLUSIVE (R5) — Cargo has no native"
      f.puts "// concept of that, and `default = [#{target_mod_name.inspect}]` in"
      f.puts "// Cargo.toml stays enabled unless a build passes"
      f.puts "// `--no-default-features`, so a plain `cargo build --features banking`"
      f.puts "// used to enable BOTH the default domain's feature and banking's,"
      f.puts "// producing two `pub use ... as active;` imports and a hard E0252."
      f.puts "// Fixed two ways below, entirely mechanically from `domains`/"
      f.puts "// `target_mod_name` (this run's new default) — never hand-maintained:"
      f.puts "//"
      f.puts "//   1. THE DEFAULT DOMAIN'S OWN re-export backs off whenever any OTHER"
      f.puts "//      domain feature is also enabled, so it never contends for `active`"
      f.puts "//      by accident — `cargo build --features banking` (still implicitly"
      f.puts "//      carrying the default feature) now resolves to banking alone,"
      f.puts "//      same as if `--no-default-features` had been passed explicitly."
      f.puts "//   2. Two NON-default domain features enabled TOGETHER (a genuine,"
      f.puts "//      not-accidental conflict — nothing makes that combination"
      f.puts "//      meaningful) still fail the build, but with an explicit"
      f.puts "//      `compile_error!` naming both features instead of a cryptic"
      f.puts "//      \"defined multiple times\"."
      domains.each do |name|
        other_domains = domains - [name]
        if name == target_mod_name && !other_domains.empty?
          guard = other_domains.map { |o| "feature = #{o.inspect}" }.join(", ")
          f.puts "#[cfg(all(feature = #{name.inspect}, not(any(#{guard}))))]"
        else
          f.puts "#[cfg(feature = #{name.inspect})]"
        end
        f.puts "pub use #{name}::merged as active;"
      end
      non_default_domains = domains - [target_mod_name]
      if non_default_domains.size > 1
        f.puts
        f.puts "// Explicit conflict guard — see point 2 above. Only fires when TWO"
        f.puts "// non-default domain features are both turned on; the default"
        f.puts "// domain's own feature never reaches here (point 1 already excludes"
        f.puts "// it whenever any other domain feature is present)."
        non_default_domains.combination(2).each do |a, b|
          f.puts "#[cfg(all(feature = #{a.inspect}, feature = #{b.inspect}))]"
          f.puts "compile_error!(\"domain features are mutually exclusive — enable only one of: #{domains.join(', ')} (both #{a} and #{b} are enabled)\");"
        end
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
    # Scoped to the [features] table only — checking against the whole
    # file false-positives against [package]/[lib] keys sharing a word
    # with a domain name (version, edition, name, path, ...).
    features_table = cargo_toml[/^\[features\](?:\n(?!\[).*)*$/] || ""
    domains.each do |name|
      next if features_table =~ /^#{Regexp.escape(name)}\s*=/

      cargo_toml = cargo_toml.sub(/^default\s*=.*$/) { "#{Regexp.last_match(0)}\n#{name} = []" }
      features_table = cargo_toml[/^\[features\](?:\n(?!\[).*)*$/] || ""
    end
    cargo_toml = cargo_toml.sub(/^default\s*=.*$/, "default = [#{target_mod_name.inspect}]")
    File.write(cargo_toml_path, cargo_toml)
    puts "wrote #{cargo_toml_path} (default feature: #{target_mod_name})"
  end
end
