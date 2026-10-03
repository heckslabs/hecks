# frozen_string_literal: true

require "fileutils"
require "json"
require_relative "../../hecks"
require_relative "../bluebook/meta_validator"
require_relative "../ports/persistence/plugins/era"
require_relative "../../../rust/project"

module Hecks
  module RustBuild
    # Generates Rust source for one domain into the workspace's `src/generated/`, and keeps the
    # workspace's `Cargo.toml` features in step.
    #
    #   ProjectRust.call(["path/to/domain"])
    #
    # `hecks-codegen` (`rust/codegen`) is the generator (ADR 0086): this class builds the IR from
    # the live registry and `CodegenRun` runs the binary on it. `HECKS_CODEGEN=ruby` selects the
    # Ruby generator in `rust/project` instead, until that is deleted; with `HECKS_PARSER=rust` and
    # `HECKS_CODEGEN=rust` together, the whole pipeline runs through `rust/project_rust_pipeline.rb`
    # with no Ruby load of the domain.
    #
    # The era plugin is required unconditionally so the generator works for any domain, lineage
    # capable or not; `pg` stays lazy inside it, so nothing here opens a database connection.
    class ProjectRust
      # The optional attachments `rust/host` reads from `ir.json`, each omitted when nothing
      # attached provides it: exporter method, then the key it is written under.
      SEAMS = %i[authorization membership identity newsletter newsletter_issues payments
                 registrations payment_connection].freeze

      # @param argv [Array<String>] the domain's directory
      # @return [Integer] the exit status
      # @raise [Failure] when the domain's name cannot be a Rust module and Cargo feature name
      def self.call(argv)
        domain = argv.first or raise Failure, "usage: hecks project_rust <domain>"
        new(domain).call
      end

      # @param domain [String] the domain's directory
      def initialize(domain)
        @domain = domain
        @mod_name = File.basename(domain)
      end

      # @return [Integer] the exit status
      def call
        validate_name!
        if ENV["HECKS_PARSER"] == "rust" && ENV["HECKS_CODEGEN"] == "rust"
          require_relative "../../../rust/project_rust_pipeline"
          RustProjectPipeline.call(@domain)
        else
          generate
        end
        0
      end

      private

      # The name becomes a directory, a `pub mod` identifier and a Cargo feature, so it is checked
      # before any side effect (the `meta/` directory is rewritten below).
      def validate_name!
        return if RustProjection::Projector.valid_domain_mod_name?(@mod_name)

        raise Failure, "hecks project_rust: domain name #{@mod_name.inspect} (from #{@domain.inspect}) can't " \
                       "be used as-is — it has to double as a Rust module identifier and a Cargo feature " \
                       "name, and this one is either not a plain lowercase identifier, is a Rust keyword, " \
                       "or collides with a reserved Cargo.toml key " \
                       "(#{RustProjection::Projector::CARGO_RESERVED_DOMAIN_NAMES.join(', ')}). " \
                       "Rename the domain directory."
      end

      def generate
        load_registry
        @rust_dir = ENV.fetch("HECKS_RUST_DIR", File.join(RustBuild::ROOT, "rust"))
        @out_root = File.join(@rust_dir, "src/generated")
        FileUtils.mkdir_p(@out_root)
        build_target_ir
        FileUtils.rm_rf(File.join(@out_root, "active"))
        ENV["HECKS_CODEGEN"] == "ruby" ? generate_with_ruby : generate_with_codegen
        write_root_mod
        sync_cargo_features
      end

      # The rollback path (ADR 0086 step 2): the Ruby generator in `rust/project`, until it is deleted.
      def generate_with_ruby
        write_meta
        write_target
      end

      # `hecks-codegen` is the generator; this process only builds the IR it reads from the live
      # registry, so a domain's persistence, seams, translations and source text reach `ir.json`.
      def generate_with_codegen
        meta = Hecks::Projector::Exporter.call(Hecks::Bluebook::MetaValidator.grammar_registry).fetch("Bluebook")
        vendored = @registry.hecksagons.values.flat_map(&:vendored_bluebooks)
        chapters = (@registry.bluebooks.keys - [@domain_name]).map do |name|
          ir = Hecks::Projector::Exporter.call(@registry).fetch(name)
          CodegenRun::Chapter.new(name.downcase, "#{@domain} (#{attachment(name, vendored)})", prepared_ir(ir))
        end
        CodegenRun.new(
          out_root: @out_root, meta: prepared_ir(meta), chapters: chapters,
          target: CodegenRun::Chapter.new(@mod_name, @domain, prepared_ir(@ir, shaped: false))
        ).call
      end

      # The IR as `rust/project` hands it to its generators: string-keyed through JSON, with the
      # append-optional fields marked, since `ir.json` records them.
      def prepared_ir(tree, shaped: true)
        tree = json_shaped(tree) if shaped
        value_objects = tree[:aggregates].flat_map { |aggregate| aggregate[:value_objects] }.to_h { |vo| [vo[:name], vo] }
        tree[:aggregates].each do |aggregate|
          local = aggregate[:value_objects].to_h { |vo| [vo[:name], vo] }
          RustProjection::Projector.mark_append_optional_fields!(aggregate, value_objects.merge(local))
        end
        tree
      end

      # Round-trips a value through JSON so generators see the string-keyed shape a real `ir.json`
      # carries, never live Ruby symbols.
      def json_shaped(payload) = JSON.parse(JSON.generate(payload), symbolize_names: true)

      # `root:` is the domain's own directory: a domain that declares `uses_embryonaut_bluebook`
      # resolves its vendored chapters beneath it.
      def load_registry
        @registry = Hecks::Runtime::Registry.new(root: File.expand_path(@domain))
        Hecks.with_registry(@registry) do
          lib = File.expand_path("..", __dir__)
          %w[ports/persistence.port ports/extraction.port adapters/driven/memory.adapter
             adapters/driven/prism.adapter adapters/driven/postgres_era.adapter].each do |file|
            Kernel.load(File.join(lib, file))
          end
          @bluebook_dir = File.join(@domain, "bluebook")
          Hecks::Adapters::Folder.new.load_bluebooks(@bluebook_dir)
          load_siblings
          load_environment
        end
        @domain_name = @registry.bluebooks.keys.first
      end

      # Translation edges, hecksagons (whose `uses_framework` loads a framework chapter into the
      # same registry) and worlds (whose `default_adapter` binds what a hecksagon leaves out), in
      # the order the language loads them.
      def load_siblings
        Dir[File.join(@bluebook_dir, "translations", "*.bluebook")].each { |file| Kernel.load(file) }
        Dir.glob(File.join(@bluebook_dir, "*.hecksagon")).each { |file| Kernel.load(file) }
        Dir.glob(File.join(@bluebook_dir, "*.world")).each { |file| Kernel.load(file) }
      end

      # Production is the default environment when `environments/production.hecksagon` exists
      # (`rust/host` is the production runtime); `HECKS_PROJECT_ENVIRONMENT` overrides it.
      def load_environment
        environment = ENV.fetch("HECKS_PROJECT_ENVIRONMENT") do
          File.exist?(File.join(@bluebook_dir, "environments", "production.hecksagon")) ? "production" : nil
        end
        return if environment.nil? || environment.empty?

        folder = Hecks::Adapters::Folder.new
        folder.load_each(@bluebook_dir, [File.join("environments", "#{environment}.hecksagon")])
        folder.load_each(@bluebook_dir, [File.join("environments", "#{environment}.world")])
      end

      # The target's IR, with the binding facts that ride beside it (they are not shape facts, so
      # `bluebook.to_h` never mentions them).
      def build_target_ir
        exporter = Hecks::Projector::Exporter
        @ir = json_shaped(exporter.call(@registry).fetch(@domain_name))
        @ir[:lineage] = json_shaped(exporter.lineage(@registry, @domain_name))
        @ir[:persistence] = json_shaped(exporter.persistence(@registry, @domain_name))
        seams = SEAMS.to_h { |seam| [seam, exporter.public_send(seam, @registry, @domain_name)] }
        seams.each { |seam, value| @ir[seam] = json_shaped(value) unless value.empty? }
        if !seams[:membership].empty? && seams[:identity].empty?
          raise Failure, "#{@domain_name} provides membership but not identity — rust/host Google sign-in " \
                         "cannot register or link an identity from ir.json. Attach Identity " \
                         "(`uses_framework \"Identity\"` plus a sibling Hecks.hecksagon \"Identity\") so the " \
                         "hecksagon, not a deploy-time guess, names the identity verbs."
        end
        add_edges_and_source
      end

      # Edges carry their own precompiled SQL, so a boot-time mint only executes it. Committed
      # approvals sit beside the edges. The source text is verbatim: the era's integrity digest is
      # the SHA256 of it, not of anything re-derived from the parsed IR.
      def add_edges_and_source
        edges = Hecks::Projector::Exporter.translations(@registry).select { |edge| edge[:domain] == @domain_name }
        @ir[:translations] = json_shaped(edges)
        approvals = Hecks::Translation::ApprovalFile.read_all(@bluebook_dir)
        @ir[:approvals] = json_shaped(approvals) unless approvals.empty?
        @ir[:source_text] = Hecks::Runtime::EraCheck.source_text_for(
          @registry.bluebooks.fetch(@domain_name), @bluebook_dir, registry: @registry
        )
      end

      # The self-hosted language goes through the same codegen as the target, read from the
      # grammar registry `MetaValidator` boots with.
      def write_meta
        meta_ir = json_shaped(
          Hecks::Projector::Exporter.call(Hecks::Bluebook::MetaValidator.grammar_registry).fetch("Bluebook")
        )
        dir = File.join(@out_root, "meta")
        # Tracked per directory: several domains coexist on disk, and `pop_and_prune` deletes only
        # the files this run never touched. `active` is a set of feature re-exports in the root
        # `mod.rs`, never a directory.
        RustProjection::WriteIfChanged.push_directory(dir)
        result = RustProjection::DomainGenerator.call(
          meta_ir, "the self-hosted language (lib/hecks/language/bluebook)", dir, "meta"
        )
        write_merged(File.join(dir, "merged.rs"), result[:aggregates], result[:queries], result[:read_models],
                     policies: RustProjection::Projector.emit_policy_table(meta_ir[:name], meta_ir[:policies],
                                                                           meta_ir[:aggregates]),
                     cross:    RustProjection::Projector.emit_cross_domain_policy_table(meta_ir[:name],
                                                                                        meta_ir[:policies]),
                     managers: meta_ir[:process_managers],
                     keys:     [[meta_ir[:name], result[:aggregates].map { |a| a[:name] }]])
        append_merged_mod(File.join(dir, "mod.rs"))
        RustProjection::WriteIfChanged.pop_and_prune(dir)
      end

      def write_target
        dir = File.join(@out_root, @mod_name)
        RustProjection::WriteIfChanged.push_directory(dir)
        result = RustProjection::DomainGenerator.call(@ir, @domain, dir, @mod_name)
        chapters = write_chapters
        aggregates = result[:aggregates] + chapters[:aggregates]
        write_merged(File.join(dir, "merged.rs"), aggregates, result[:queries] + chapters[:queries],
                     result[:read_models] + chapters[:read_models],
                     policies: RustProjection::Projector.emit_merged_policy_table(chapters[:policy_sources]),
                     cross:    RustProjection::Projector.emit_merged_cross_domain_policy_table(chapters[:policy_sources]),
                     managers: @ir[:process_managers] + chapters[:process_managers],
                     keys:     reference_keys(result[:aggregates], chapters))
        append_merged_mod(File.join(dir, "mod.rs"))
        RustProjection::WriteIfChanged.pop_and_prune(dir)
      end

      # Every other bluebook the target's `uses_framework` calls pulled into the registry, each
      # generated into its own module. A framework chapter is a function of its bluebook alone, so
      # regenerating one is safe whichever domain last touched it.
      def write_chapters
        totals = { aggregates: [], queries: [], read_models: [], process_managers: [],
                   policy_sources: [{ domain_name: @domain_name, policies: @ir[:policies],
                                      aggregates: @ir[:aggregates] }],
                   mod_names: { @mod_name => @domain_name } }
        vendored = @registry.hecksagons.values.flat_map(&:vendored_bluebooks)
        (@registry.bluebooks.keys - [@domain_name]).each { |chapter| write_chapter(chapter, vendored, totals) }
        totals
      end

      def write_chapter(chapter_name, vendored, totals)
        mod_name = chapter_name.downcase
        totals[:mod_names][mod_name] = chapter_name
        chapter_ir = json_shaped(Hecks::Projector::Exporter.call(@registry).fetch(chapter_name))
        result = nil
        RustProjection::WriteIfChanged.track_directory(File.join(@out_root, mod_name)) do
          result = RustProjection::DomainGenerator.call(chapter_ir, "#{@domain} (#{attachment(chapter_name, vendored)})",
                                                        File.join(@out_root, mod_name), mod_name,
                                                        merged_module: false)
        end
        totals[:aggregates].concat(result[:aggregates])
        totals[:queries].concat(result[:queries])
        totals[:read_models].concat(result[:read_models])
        totals[:process_managers].concat(chapter_ir[:process_managers])
        totals[:policy_sources] << { domain_name: chapter_name, policies: chapter_ir[:policies],
                                     aggregates: chapter_ir[:aggregates] }
      end

      # How the target attached a chapter, across every hecksagon the registry loaded: a chapter a
      # sibling hecksagon vendors in is labelled as vendored.
      def attachment(chapter_name, vendored)
        name = vendored.find { |candidate| Hecks::Naming.pascal(candidate.to_s) == chapter_name }
        name ? "uses_embryonaut_bluebook #{name.inspect}" : "uses_framework #{chapter_name.inspect}"
      end

      def reference_keys(target_aggregates, chapters)
        chapters[:mod_names].map do |mod_name, chapter_name|
          own = mod_name == @mod_name ? target_aggregates : chapters[:aggregates].select { |a| a[:chapter_mod] == mod_name }
          [chapter_name, own.map { |a| a[:name] }]
        end
      end

      # Writes a module's `merged.rs`: the registry and every dispatch table over its aggregates.
      def write_merged(path, aggregates, queries, read_models, policies:, cross:, managers:, keys:)
        projector = RustProjection::Projector
        wrote = RustProjection::WriteIfChanged.block(path) do |file|
          [projector.emit_registry(aggregates), projector.emit_reference_lookup(aggregates), policies, cross,
           projector.emit_process_manager_table(managers), projector.emit_reference_key_table(keys),
           projector.emit_creates_table(aggregates), projector.emit_identity_head_table(aggregates),
           projector.emit_entity_identity_head_table(aggregates),
           projector.emit_command_attributes_table(aggregates), projector.emit_query_table(queries),
           projector.emit_query_arg_check_table(queries)].each do |table|
            file.puts table
            file.puts
          end
          # A read model's `group_by` function is written before the table names it.
          read_models.each do |model|
            next unless model[:group_by_fn_body]

            file.puts model[:group_by_fn_body]
            file.puts
          end
          file.puts projector.emit_read_model_table(read_models)
        end
        puts(wrote ? "wrote #{path}" : "#{path} unchanged")
      end

      # Appends the `pub mod merged;` line once; appending it again would grow the file and bump
      # its mtime on every run.
      def append_merged_mod(path)
        return if File.exist?(path) && File.read(path).include?("pub mod merged;")

        File.open(path, "a") { |file| file.puts "pub mod merged;" }
      end

      # `src/generated/mod.rs`: every domain ever generated, scanned off disk. A directory is a
      # selectable domain exactly when it carries its own `merged.rs`; a framework chapter has
      # none and is always compiled in.
      def write_root_mod
        all_dirs = Dir.children(@out_root).select { |name| File.directory?(File.join(@out_root, name)) }.sort
        @domains = all_dirs.select { |name| File.exist?(File.join(@out_root, name, "merged.rs")) }
        path = File.join(@out_root, "mod.rs")
        wrote = RustProjection::WriteIfChanged.block(path) do |file|
          RootMod.new(file, all_dirs, @domains, @mod_name).write
        end
        puts(wrote ? "wrote #{path}" : "#{path} unchanged")
      end

      # One Cargo feature per domain on disk (added when missing, never removed), with `default`
      # set to this run's domain so a bare `cargo build` builds it. A feature is inserted right
      # after `default = [...]`, not appended: past `[[bin]]` it would parse into that table.
      def sync_cargo_features
        path = File.join(@rust_dir, "Cargo.toml")
        manifest = File.read(path)
        manifest = manifest.sub(/\A/, FEATURES_HEADER) unless manifest.include?("[features]")
        @domains.each { |name| manifest = add_feature(manifest, name) }
        manifest = manifest.sub(/^default\s*=.*$/, "default = [#{@mod_name.inspect}]")
        # An unchanged manifest is not rewritten: a new mtime makes Cargo rebuild the whole crate.
        if RustProjection::WriteIfChanged.call(path, manifest)
          puts "wrote #{path} (default feature: #{@mod_name})"
        else
          puts "#{path} unchanged (default feature already #{@mod_name})"
        end
      end

      # Checked against the `[features]` table only: `[package]`'s `name` or a `[[bin]]` path can
      # share a word with a domain name.
      def add_feature(manifest, name)
        table = manifest[/^\[features\](?:\n(?!\[).*)*$/] || ""
        return manifest if table =~ /^#{Regexp.escape(name)}\s*=/

        manifest.sub(/^default\s*=.*$/) { "#{Regexp.last_match(0)}\n#{name} = []" }
      end

      FEATURES_HEADER = <<~TOML
        # One feature per generated domain: it selects which domain's own
        # generated::<domain>::merged module `generated::active` re-exports
        # (rust/src/generated/mod.rs). `hecks project_rust` adds a feature when a new domain is
        # generated and never removes one (the domain's own generated/<name>/ directory is the
        # source of truth for whether it exists). `default` tracks the domain generated most
        # recently, so a bare `cargo build` keeps working; any other still-generated domain stays
        # reachable via `--no-default-features --features <name>`.
        [features]
        default = []

      TOML
      private_constant :FEATURES_HEADER
    end
  end
end

require_relative "project_rust/root_mod"
require_relative "project_rust/codegen_run"
