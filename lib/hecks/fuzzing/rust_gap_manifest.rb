require "json"
require "hecks/naming"

module Hecks
  module Fuzzing
    # What a compiled Rust binary declares it did not generate — read off the
    # `manifest.json` files `rust/project/domain_generator.rb` writes beside
    # every generated module, never inferred from Rust's refusal wording.
    #
    # The differential fuzzer (`Differential.diff`) used to drop any refusal
    # whose Rust error contained "is not generated for this domain". That
    # tolerated whatever Rust happened to say, including a codegen regression
    # that started refusing a construct it used to generate. Now a query or
    # read-model verb is dropped from the comparison if and only if the
    # generator's own manifest recorded it as `generated: false`, with the
    # `gap_class` and `construct` that explain why. A refusal the manifest
    # does not account for stays in the comparison and fails it.
    #
    # Which manifests describe a binary. `build_and_pin` (spec/support/
    # rust_conformance_helpers.rb) and `bin/qa_generated_domains` both pin a
    # feature's binary at `<rust_dir>/target/debug/rust-<feature>`. That
    # binary compiles `src/generated/<feature>/` plus every shared framework
    # chapter (a generated directory with no `merged.rs` of its own —
    # `governance`, `identity`; see the generated `mod.rs` header). Ids in
    # those manifests are domain-qualified, so a chapter a domain never
    # attaches contributes entries no sequence for that domain can name.
    #
    # A missing manifest tolerates nothing. A hand-written fixture crate, or
    # a tree generated before manifests existed, has no declaration to
    # honour, so every refusal it produces is compared as-is. That is the
    # fail-closed direction.
    class RustGapManifest
      # The only kinds the kernel answers as a query step. A not-generated
      # command changes state, so dropping its refusal would not make the
      # comparison honest; those stay compared and fail.
      TOLERABLE_KINDS = %w[query read_model].freeze
      PINNED_BINARY = %r{\A(?<rust_dir>.+)/target/debug/rust-(?<feature>[a-z0-9_]+)\z}

      attr_reader :rust_dir, :feature, :entries

      def self.for_binary(binary)
        match = PINNED_BINARY.match(File.expand_path(binary.to_s))
        unless match
          raise ArgumentError, "#{binary.inspect} is not a pinned conformance binary " \
                               "(<rust_dir>/target/debug/rust-<feature>) — cannot tell which manifest describes it"
        end

        new(rust_dir: match[:rust_dir], feature: match[:feature])
      end

      # Every committed manifest entry under `rust_dir`, each tagged with the
      # generated module it came from — what the boundary ratchet and
      # bin/rust_coverage's allowlist staleness check read.
      def self.all_entries(rust_dir)
        Dir.glob(File.join(rust_dir, "src/generated/*/manifest.json")).flat_map do |path|
          module_name = File.basename(File.dirname(path))
          JSON.parse(File.read(path)).map { |entry| entry.merge("module" => module_name) }
        end
      end

      def initialize(rust_dir:, feature:)
        @rust_dir = rust_dir
        @feature  = feature
        @entries  = manifest_paths.flat_map { |path| JSON.parse(File.read(path)) }.freeze
        @not_generated = index_not_generated
      end

      # The manifest entry that declares `verb` not generated, or nil. `verb`
      # is the wire spelling a sequence step uses; an ad hoc filter (a Hash)
      # is never declared and answers nil.
      def not_generated(verb)
        return nil unless verb.is_a?(String)

        @not_generated[verb]
      end

      def not_generated?(verb) = !not_generated(verb).nil?

      def not_generated_verbs = @not_generated.keys.to_set

      private

      def manifest_paths
        generated = File.join(rust_dir, "src/generated")
        own = File.join(generated, feature, "manifest.json")
        chapters = Dir.glob(File.join(generated, "*/manifest.json")).reject do |path|
          dir = File.dirname(path)
          File.basename(dir) == feature || File.exist?(File.join(dir, "merged.rs"))
        end
        ([own] + chapters.sort).select { |path| File.exist?(path) }
      end

      def index_not_generated
        @entries.each_with_object({}) do |entry, index|
          next unless TOLERABLE_KINDS.include?(entry["kind"]) && entry["generated"] == false

          wire_verbs(entry).each { |verb| index[verb] = entry }
        end.freeze
      end

      # A query is asked by its id. A read model's id is "Domain::Name", but
      # it is asked as "Domain.Name" or "Domain.name_in_snake_case" — the two
      # spellings `kernel::read_model::find` accepts (`matches_snake_alias`,
      # a port of `Hecks::Naming.snake`).
      def wire_verbs(entry)
        return [entry["id"]] if entry["kind"] == "query"

        domain, name = entry["id"].split("::", 2)
        ["#{domain}.#{name}", "#{domain}.#{Hecks::Naming.snake(name)}"].uniq
      end
    end
  end
end
