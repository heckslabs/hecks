require "digest"
require "fileutils"
require "open3"
require "securerandom"
require_relative "cache_dir"
require_relative "closed_form/parser"

module Hecks
  # The one way the gem reads a `.bluebook`, `.hecksagon`, `.world` or `.contextmap` file.
  #
  # The Rust parser checks the file against the closed vocabulary: declaration words with literal
  # arguments, rule expressions for `given`, `invariant`, `ensures` and `where`, operand arithmetic
  # for `sets`, and the open bind and setting verbs of a hecksagon and a world, never one that names
  # a Ruby method. It answers the text it admitted, line for line, without the comments. The gem
  # evaluates that text, never the file, so a file holding anything else is refused before it runs.
  #
  # The text is evaluated under the file's own path, at its own line numbers, so source locations
  # and a rule's recovered source are the file's. A file written as sentences (`Domain:` first) is
  # rendered by the parser, checked the same way, and loaded from a generated file of its own.
  module ClosedForm
    # The extensions of the files only the closed form reads.
    EXTENSIONS = %w[.bluebook .hecksagon .world .contextmap].freeze

    # The line a sentence-form bluebook opens with, after any blank or comment lines.
    DOMAIN_LINE = /\A\s*Domain:/

    # The parser's flag for frozen era text, which keeps the spellings it was written in.
    FROZEN = "--frozen".freeze

    # Raised when a file reaches outside the closed vocabulary; the message is the parser's
    # diagnostic, `path:line[:column]: why`.
    class Refused < StandardError; end

    module_function

    # @param path [String] any file the gem boots from
    # @return [Boolean] whether only the closed form may read it
    def closed?(path) = EXTENSIONS.include?(File.extname(path.to_s))

    # Loads a file the gem boots from: a declaration file through the closed form, and anything
    # else (a `.port`, an `.adapter`, Ruby) as Ruby.
    #
    # @param path [String] the file
    # @return [void]
    # @raise [Refused] if a declaration file reaches outside the closed vocabulary
    def load_file(path)
      closed?(path) ? load(path) : Kernel.load(path)
      nil
    end

    # Declares what a `.bluebook`, `.hecksagon`, `.world` or `.contextmap` file holds, in the
    # registry now current.
    #
    # @param path [String] the file
    # @return [void]
    # @raise [Refused] if it reaches outside the closed vocabulary
    # @raise [Parser::Missing] if no parser can be found or built
    # @raise [LoadError] if there is no such file
    def load(path) = load_text(source_of(path.to_s), path.to_s)

    # Declares what `source` holds as though it were the file at `path`: text held from an earlier
    # era, or a bluebook spread over files and held as one string of its blocks.
    #
    # @param source [String] declaration text
    # @param path [String] the file it stands for, which a refusal and a source location name
    # @return [void]
    # @raise [Refused] if it reaches outside the closed vocabulary
    def load_text(source, path)
      text = admitted(source, path)
      sentences?(source, path) ? load_rendered(path, text) : evaluate(text, path)
      nil
    end

    # The text a file holds now. Codemod's dry run prepends a stand-in here for a file it has
    # staged an edit for, so the edit is judged without being written.
    #
    # @param path [String] the file
    # @return [String] its source
    # @raise [LoadError] when there is no such file, as `Kernel.load` raises
    def source_of(path)
      File.read(path, encoding: Encoding::UTF_8)
    rescue Errno::ENOENT
      raise LoadError, "cannot load such file -- #{path}"
    end

    # The text the parser admits for `source`, read from the cache when this parser has admitted
    # the same text under the same name, in the same era, before. While the gem shadow-parses,
    # `source` is read as frozen era text.
    #
    # @param source [String] a declaration file's text
    # @param label [String] the file's path, which a refusal names
    # @return [String] the admitted text
    # @raise [Refused] if the text reaches outside the closed vocabulary
    def admitted(source, label)
      cached = cache_file(source, label)
      return File.read(cached, encoding: Encoding::UTF_8) if File.file?(cached)

      text = run_parser(source, label)
      write_atomically(cached, text)
      text
    end

    # @return [String] the admitted text, straight from the parser
    # @raise [Refused] if the parser refuses the text
    def run_parser(source, label)
      out, err, status = Open3.capture3(Parser.binary, "closed", *era, "--stdin", label, stdin_data: source)
      raise Refused, err.force_encoding(Encoding::UTF_8).strip unless status.success?

      out.force_encoding(Encoding::UTF_8)
    end
    private_class_method :run_parser

    # @return [Array<String>] the parser's `--frozen` flag while the gem shadow-parses frozen era
    #   text, so a spelling it was written in (`process_manager`) is admitted; none for live source
    def era
      frozen = defined?(Hecks::Bluebook::MetaValidator) && Hecks::Bluebook::MetaValidator.shadow_parsing?
      frozen ? [FROZEN] : []
    end
    private_class_method :era

    # Evaluates admitted text at the top level, under the file's own path and line numbers.
    #
    # @param text [String] text the parser admitted
    # @param path [String] the file it was admitted for
    # @return [void]
    def evaluate(text, path)
      eval(text, TOPLEVEL_BINDING.dup, path, 1)
    end
    private_class_method :evaluate

    # A sentence file's admitted text is the rendered Ruby form, whose lines are not the sentence
    # file's, so it loads from a file of its own (a rule's source is recovered from the file it
    # was written in) and the registry then names the sentence file as the source.
    def load_rendered(path, text)
      require_relative "sentence_form"
      generated = SentenceForm.write_generated(path, text)
      evaluate(text, generated)
      SentenceForm.point_sources_at(generated, path)
    end
    private_class_method :load_rendered

    # @return [Boolean] whether `source` is a sentence-form bluebook: a `.bluebook` whose first
    #   line that is neither blank nor a comment is its `Domain:` line
    def sentences?(source, path)
      return false unless path.end_with?(".bluebook")

      first = source.each_line.find { |line| !line.strip.empty? && !line.lstrip.start_with?("#") }
      first.to_s.match?(DOMAIN_LINE)
    end
    private_class_method :sentences?

    # @return [String] where the admitted text of `source` under `label` is kept, named by the
    #   parser that admitted it, the era it was read in, the label and the text
    def cache_file(source, label)
      key = Digest::SHA256.hexdigest([Parser.identity, *era, label, source].join("\0"))
      File.join(CacheDir.path("closed_form"), key[0, 2], "#{key}.rb")
    end
    private_class_method :cache_file

    # Writes through a temporary file and a rename, so a parallel reader sees all of it or none.
    def write_atomically(file, text)
      FileUtils.mkdir_p(File.dirname(file))
      temporary = "#{file}.#{SecureRandom.hex(8)}"
      File.write(temporary, text)
      File.rename(temporary, file)
    end
    private_class_method :write_atomically
  end
end
