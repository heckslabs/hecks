# frozen_string_literal: true

require "fileutils"
require "json"
require "tempfile"

module Hecks
  # What each `project_*` generator of the language writes, held as data: absolute path to text.
  #
  # The tables of the language (the model's holding half, the vocabulary, the parser's keywords, the
  # Rust vocabulary, reserved names, field hints, the expression tables and the DSL reference) are
  # projected from the Bluebook chapter's own declarations. Building them apart from writing them
  # lets a caller compare a projection with the tree before anything is changed: a `bin/` script
  # writes the answer, and the Hecks domain's Language commands report drift and write only when
  # confirmed.
  module ProjectionFiles
    # The repository root this file lives in.
    ROOT = File.expand_path("../..", __dir__)

    # Raised when a projection would leave the language unable to boot.
    class Refused < StandardError; end

    # The files a projection writes, and the ones it leaves stale.
    #
    # @!attribute [r] content
    #   @return [Hash{String => String}] absolute path to the text it should hold
    # @!attribute [r] stale
    #   @return [Array<String>] absolute paths the projection does not emit and removes
    Result = Struct.new(:content, :stale)

    # Rust keyword and Cargo name tables, by the constant each becomes.
    RESERVED_TABLES = {
      "RUST_KEYWORDS"               => "RustReservedWord",
      "CARGO_RESERVED_DOMAIN_NAMES" => "CargoReservedName"
    }.freeze

    # Names of the projections, in the order a full regeneration runs them.
    NAMES = %i[model vocabulary rust_vocabulary reserved_names parser_table bootstrap_table
               field_hints expression_tables reference].freeze

    module_function

    # Builds one projection without writing anything.
    #
    # @param name [Symbol] one of `NAMES`
    # @param root [String] the checkout the projection is for
    # @return [Result] what it would write and remove
    # @raise [ArgumentError] if the projection is not known
    # @raise [Refused] if the projection would leave the language unable to boot
    def build(name, root: ROOT)
      raise ArgumentError, "no projection named #{name.inspect}" unless NAMES.include?(name.to_sym)

      public_send(name, root)
    end

    # Writes one projection, each file through a temporary file and a rename so a reader never sees
    # a partial file, and removes what it does not emit.
    #
    # @param name [Symbol] one of `NAMES`
    # @param root [String] the checkout the projection is for
    # @return [Array<String>] one `wrote <path>` or `removed <path>` line for each change
    def write(name, root: ROOT)
      result = build(name, root: root)
      lines = result.content.map { |path, text| write_atomically(path, text) }
      lines + result.stale.map { |path| File.delete(path) && "removed #{path}" }
    end

    # Writes one projection and prints what changed, as the `project_*` commands do.
    #
    # @param name [Symbol] one of `NAMES`
    # @param root [String] the checkout the projection is for
    # @return [void] the `wrote`/`removed` lines go to stdout
    # @raise [SystemExit] with the reason on stderr when the projection is refused
    def run(name, root: ROOT)
      puts write(name, root: root)
    rescue Refused => e
      abort e.message
    end

    # Replaces a file through a same-directory temporary file and a rename.
    #
    # @param target [String] the file to write
    # @param text [String] what it holds afterwards
    # @return [String] the `wrote <path>` line
    def write_atomically(target, text)
      FileUtils.mkdir_p(File.dirname(target))
      Tempfile.create(File.basename(target), File.dirname(target)) do |tmp|
        tmp.write(text)
        tmp.flush
        File.rename(tmp.path, target)
      end
      "wrote #{target}"
    end

    # @param root [String] the checkout
    # @return [Result] the model's holding half, one file for each thing the chapter holds
    def model(root)
      require "hecks"
      files = Projector.call(:model, bluebook: chapter)
      out = File.join(root, "lib/hecks/bluebook")
      Result.new(files.to_h { |relative, text| [File.join(out, relative), text] }, [])
    end

    # @param root [String] the checkout
    # @return [Result] `lib/hecks/vocabulary.rb`, the language's closed sets
    def vocabulary(root)
      require "hecks"
      Result.new({ File.join(root, "lib/hecks/vocabulary.rb") => artifact_text(:vocabulary) }, [])
    end

    # @param root [String] the checkout
    # @return [Result] one Rust enum a table under `rust/src/kernel/vocab/`; files it does
    #   not emit are stale
    def rust_vocabulary(root)
      require "hecks"
      kernel = File.join(root, "rust/src/kernel")
      files = Projector.call(:rust_vocabulary, bluebook: chapter)
      content = files.to_h { |relative, text| [File.join(kernel, relative), text] }
      Result.new(content, Dir.glob(File.join(kernel, "vocab", "*.rs")) - content.keys)
    end

    # @param root [String] the checkout
    # @return [Result] `reserved_names.rs` for the codegen and build crates, which share no library
    # @raise [Refused] if a vocabulary declares no members
    def reserved_names(root)
      require "hecks/vocabulary"
      consts = RESERVED_TABLES.map do |const, vocabulary|
        words = Hecks::Vocabulary.fetch(vocabulary)
        raise Refused, "vocabulary #{vocabulary} declares no members" if words.empty?

        lines = words.map { |word| "    #{word.inspect}," }.join("\n")
        "/// The `#{vocabulary}` vocabulary, #{words.size} entries.\n" \
          "pub const #{const}: &[&str] = &[\n#{lines}\n];"
      end
      text = reserved_names_text(consts)
      targets = %w[rust/codegen/src/reserved_names.rs rust/build/src/reserved_names.rs]
      Result.new(targets.to_h { |target| [File.join(root, target), text] }, [])
    end

    # @param root [String] the checkout
    # @return [Result] the Rust parser's keyword table
    def parser_table(root)
      require "hecks"
      Result.new({ File.join(root, "rust/parser/src/keywords.rs") => artifact_text(:parser_table) }, [])
    end

    # @param root [String] the checkout
    # @return [Result] the DSL's bootstrap-window fallbacks
    def bootstrap_table(root)
      require "hecks"
      path = File.join(root, "lib/hecks/bluebook/dsl/bootstrap_table.rb")
      Result.new({ path => artifact_text(:bootstrap_table) }, [])
    end

    # @param root [String] the checkout
    # @return [Result] `rust/host/src/field_hints.rs`, the hints the host's form fields guess from
    def field_hints(root)
      require "hecks"
      vocabulary = chapter.aggregates.find { |aggregate| aggregate.hecks_name == "Vocabulary" }
      field_hint = vocabulary.value_objects.find { |value_object| value_object.hecks_name == "FieldHint" }
      hints = field_hint.members.map(&:to_h)
      Result.new({ File.join(root, "rust/host/src/field_hints.rs") => field_hints_text(hints) }, [])
    end

    # @param root [String] the checkout
    # @return [Result] `lib/hecks/bluebook/expression/projection.json`
    # @raise [Refused] if an admitted operator has no declared algebra, or the projection drops an
    #   operator the language's own guards evaluate through
    def expression_tables(root)
      require "hecks"
      require "hecks/grammar"
      operators = expression_operators(Grammar.expression)
      dropped = Grammar.self_bearing_operators.except(*operators.map { |row| row[:symbol] })
      raise Refused, dropped_message(dropped) unless dropped.empty?

      dispatcher = Grammar.expression
      text = "#{JSON.pretty_generate(operators: operators, normalisations: Grammar.admitted_normalisations(dispatcher))}\n"
      Result.new({ File.join(root, "lib/hecks/bluebook/expression/projection.json") => text }, [])
    end

    # The DSL reference pages and the README regions generated from the same declarations.
    #
    # @param root [String] the checkout
    # @return [Result] every page of `docs/implemented/reference/` and `README.md`
    def reference(root)
      require "hecks"
      directory = File.join(root, "docs/implemented/reference")
      pages = Projector.call(:reference, bluebook: chapter, options: { from: directory })
      content = pages.to_h { |relative, text| [File.join(directory, relative), text] }
      readme = File.join(root, "README.md")
      content[readme] = Doc::Reference.render_readme(root, File.read(readme))
      Result.new(content, [])
    end

    # @param projection [Symbol] a projection registered with the projector
    # @return [String] what it projects from the Bluebook chapter, as the text a file holds
    def artifact_text(projection)
      artifact = Projector.call(projection, bluebook: chapter)
      artifact.is_a?(String) ? artifact : "#{JSON.pretty_generate(artifact)}\n"
    end

    # @return [Bluebook::Aggregate] the Bluebook chapter, which every projection reads
    def chapter
      Bluebook::MetaValidator.grammar_registry.bluebook("Bluebook")
    end

    # @param dispatcher [Object] the expression dispatcher
    # @return [Array<Hash>] each admitted operator, with the algebra a comparison declares
    # @raise [Refused] if a comparison has no declared algebra
    def expression_operators(dispatcher)
      vocabulary = chapter.aggregates.find { |aggregate| aggregate.name == "Vocabulary" }
      algebra = vocabulary.value_objects.find { |value_object| value_object.hecks_name == "Comparison" }
                          .members.to_h { |row| [row.to_h.values.first, row.to_h] }
      Grammar.admitted_operators(dispatcher).map do |op|
        row = { symbol: op[:symbol], category: op[:category], precedence: op[:precedence], arity: op[:arity] }
        next row unless op[:category] == "comparison"

        declared = algebra.fetch(op[:symbol]) do
          raise Refused, "#{op[:symbol]} is admitted but Vocabulary::Comparison declares no algebra for it"
        end
        row.merge(compares_less_than: declared[:compares_less_than],
                  compares_equal: declared[:compares_equal], negated: declared[:negated])
      end
    end

    # @param dropped [Hash{String => Array<String>}] operator to the guards evaluating through it
    # @return [String] one line for each operator a projection would strand
    def dropped_message(dropped)
      dropped.map do |symbol, sites|
        "#{symbol} is self-bearing — the language's own predicates evaluate through it " \
          "(#{sites.first(3).join('; ')}) — rewrite those guards before retiring it"
      end.join("\n")
    end

    # @param consts [Array<String>] the rendered Rust constants
    # @return [String] the whole `reserved_names.rs`
    def reserved_names_text(consts)
      <<~RUST
        // GENERATED by bin/project_reserved_names from the RustReservedWord and
        // CargoReservedName vocabularies (lib/hecks/language/bluebook/
        // vocabulary.bluebook). Do not hand-edit — re-run bin/project_reserved_names.

        #{consts.join("\n\n")}
      RUST
    end

    # @param hints [Array<Hash>] the rows of `Vocabulary::FieldHint`
    # @return [String] the whole `field_hints.rs`
    def field_hints_text(hints)
      consts = hints.map { |hint| field_hint_constant(hint) }.join("\n")
      <<~RUST
        // GENERATED by bin/project_field_hints from Vocabulary::FieldHint
        // (lib/hecks/language/bluebook/vocabulary.bluebook). Do not
        // hand-edit — re-run bin/project_field_hints instead.
        //
        // web.rs's `text_field` matches these in the SAME precedence Ruby's
        // own `text_field` does: EMAIL_HINT, then URL_HINT, then TEL_HINT —
        // against `html_type`, first match wins — then, only if `html_type`
        // stayed "text", TEXTAREA_HINT against `kind`.

        use regex::Regex;
        use std::sync::LazyLock;

        #{consts}
      RUST
    end

    # @param hint [Hash] one `FieldHint` row: its name, pattern and what it resolves to
    # @return [String] the Rust `static` for it
    def field_hint_constant(hint)
      name = "#{hint[:name].upcase}_HINT"
      <<~RUST
        /// #{hint[:name].capitalize} hint, resolving to `#{hint[:resolves_to]}` on a match —
        /// Vocabulary::FieldHint's own declared pattern, unmodified (the
        /// same text `Regexp#source` reads off FieldShape's own
        /// #{name}, which is built from this same row).
        /// `(?i)` up front is this crate's spelling
        /// of Ruby's trailing `/i` — the WHOLE pattern is case-insensitive
        /// on both sides, never partially.
        pub static #{name}: LazyLock<Regex> =
            LazyLock::new(|| Regex::new(r#"(?i)#{hint[:pattern]}"#).expect("declared field-hint pattern must compile"));
      RUST
    end
  end
end
