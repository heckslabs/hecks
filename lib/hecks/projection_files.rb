# frozen_string_literal: true

require "fileutils"
require "json"
require "tempfile"
require_relative "projection_files/texts"
require_relative "projection_files/expression_tables"

module Hecks
  # What each `project_*` generator of the language writes, held as data: absolute path to text.
  #
  # The tables of the language (the model's holding half, the vocabulary, the parser's keywords, the
  # Rust vocabulary, reserved names, field hints, the expression tables and the DSL reference) are
  # projected from the Bluebook chapter's own declarations. Building them apart from writing them
  # lets a caller compare a projection with the tree before anything is changed: a
  # `hecks project_*` verb writes the answer, and the Hecks domain's Language commands report
  # drift and write only when confirmed.
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

    extend Texts
    extend ExpressionTables

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
      text = reserved_names_text(RESERVED_TABLES.map { |const, vocabulary| reserved_constant(const, vocabulary) })
      targets = %w[rust/codegen/src/reserved_names.rs rust/build/src/reserved_names.rs]
      Result.new(targets.to_h { |target| [File.join(root, target), text] }, [])
    end

    # @param const [String] the Rust constant's name
    # @param vocabulary [String] the vocabulary its words come from
    # @return [String] the Rust `pub const` listing every word
    # @raise [Refused] if the vocabulary declares no members
    def reserved_constant(const, vocabulary)
      words = Hecks::Vocabulary.fetch(vocabulary)
      raise Refused, "vocabulary #{vocabulary} declares no members" if words.empty?

      lines = words.map { |word| "    #{word.inspect}," }.join("\n")
      "/// The `#{vocabulary}` vocabulary, #{words.size} entries.\n" \
        "pub const #{const}: &[&str] = &[\n#{lines}\n];"
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
  end
end
