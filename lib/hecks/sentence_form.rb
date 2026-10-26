require "digest"
require "fileutils"
require "open3"
require_relative "cache_dir"

module Hecks
  # A `.bluebook` written as plain sentences (its first line is `Domain: <name>`) rather than in
  # the Ruby form. The Rust parser is the one reader of the sentences: it renders them as the
  # Ruby-shaped text that declares the same chapter, and Ruby evaluates that text under the
  # sentence file's own path, so the registry records the file the author wrote.
  module SentenceForm
    # The repository root, where the parser's build lands under `rust/parser/target/`.
    ROOT = File.expand_path("../..", __dir__).freeze

    # The line a sentence-form file opens with, after any blank or comment lines.
    DOMAIN_LINE = /\A\s*Domain:/

    # The first line of a tool's output, without its newline.
    FIRST_LINE = /\A[^\n]*/

    # A `Hecks.bluebook "Name"` header line, or a `Domain: name` line, capturing the chapter's name.
    CHAPTER_HEADER = /\A\s*(?:Hecks\.bluebook\s+"([^"]+)"|Domain:\s*(\S.*?)\s*\z)/

    # Raised when no `hecks-parse` binary can be found.
    class ParserMissing < StandardError; end

    # Raised when the parser refuses a sentence file; the message is its diagnostic.
    class Refused < StandardError; end

    module_function

    # @param path [String] a `.bluebook` file
    # @return [Boolean] whether the file is written as sentences
    def sentences?(path)
      first = File.foreach(path).find { |line| !line.strip.empty? && !line.lstrip.start_with?("#") }
      !first.nil? && first.match?(DOMAIN_LINE)
    end

    # @param path [String] a bluebook file, in either form
    # @return [String, nil] the chapter name its header declares; a `Domain:` line is read as
    #   the words capitalised and joined, as the parser reads it
    def chapter_name(path)
      File.foreach(path) do |line|
        next unless line =~ CHAPTER_HEADER

        return Regexp.last_match(1) || capitalised(Regexp.last_match(2))
      end
      nil
    end

    # @param words [String] the words of a `Domain:` line
    # @return [String] each word capitalised and the words joined, as the parser reads them
    def capitalised(words) = words.split.map { |word| word[0].upcase + word[1..] }.join

    # @param text [String] a tool's error output
    # @return [String] its first line, without the newline
    def first_line(text) = text.to_s[FIRST_LINE]

    # The Ruby-shaped text of a sentence-form file.
    #
    # @param path [String] a sentence-form `.bluebook`
    # @return [String] Ruby source declaring the same chapter
    # @raise [ParserMissing] if `hecks-parse` is not built
    # @raise [Refused] if the sentences are not ones the parser knows
    def ruby_text(path)
      chapter = chapter_name(path) or raise Refused, "#{path}: no `Domain:` line to name the chapter"
      out, err, status = Open3.capture3(binary, "render", "--chapter", chapter, path)
      raise Refused, first_line(err) unless status.success?

      out
    end

    # The extension of an examples file: sentences saying who does what to the domain and what
    # follows, which the behaviors runner runs.
    EXAMPLES_EXTENSION = ".examples".freeze

    # The first line of an examples file, naming the chapter the examples are about.
    EXAMPLES_LINE = /\A\s*Examples for:\s*(\S.*?)\s*\z/

    # @param path [String] a file the behaviors runner was asked to run
    # @return [Boolean] whether it is an examples file, not a `.behaviors` file
    def examples?(path) = path.to_s.end_with?(EXAMPLES_EXTENSION)

    # The `.behaviors` text that runs an examples file against its chapter.
    #
    # The chapter's files are the `.bluebook` beside the examples file with the same stem or, when
    # there is none, every `.bluebook` there (or in a `bluebook/` folder there) that declares the
    # chapter the examples are about.
    #
    # @param path [String] an examples file
    # @return [String] `.behaviors` source
    # @raise [ParserMissing] if `hecks-parse` is not built
    # @raise [Refused] if no chapter file is found or the examples are not ones the parser accepts
    def behaviors_text(path)
      chapter = examples_chapter(path)
      files = chapter_files(path, chapter)
      raise Refused, "#{path}: no .bluebook beside it declares #{chapter}" if files.empty?

      wiring = behaviors_hecksagon(path)
      also = wiring ? ["--also", wiring] : []
      out, err, status = Open3.capture3(binary, "examples", "--chapter", chapter, "--examples", path, *also, *files)
      raise Refused, first_line(err) unless status.success?

      out
    end

    # Writes the `.behaviors` text of an examples file where the runner can load it.
    #
    # @param path [String] an examples file
    # @return [String] the generated `.behaviors` file's path
    def write_behaviors(path)
      text = behaviors_text(path)
      dir = CacheDir.path("sentence_form")
      FileUtils.mkdir_p(dir)
      generated = File.join(dir, "#{File.basename(path, EXAMPLES_EXTENSION)}-#{Digest::SHA256.hexdigest(text)[0, 16]}.behaviors")
      File.write(generated, text) unless File.exist?(generated)
      generated
    end

    # The Memory-bound hecksagon that answers a chapter's asks while its examples run: the
    # `<name>_behaviors.hecksagon` beside the examples file, as Pizzas keeps one beside its own.
    #
    # @param path [String] an examples file
    # @return [String, nil] its absolute path, or nil when there is none
    def behaviors_hecksagon(path)
      wiring = File.join(File.dirname(File.expand_path(path)), "#{File.basename(path, EXAMPLES_EXTENSION)}_behaviors.hecksagon")
      wiring if File.file?(wiring)
    end

    # @return [String] the chapter an examples file's first line names, capitalised and joined
    def examples_chapter(path)
      line = File.foreach(path).find { |text| text.match?(EXAMPLES_LINE) }
      raise Refused, "#{path}: no `Examples for: <chapter>` line" unless line

      line.match(EXAMPLES_LINE)[1].split.map { |word| word[0].upcase + word[1..] }.join
    end

    # @return [Array<String>] absolute paths of the `.bluebook` files the examples are about
    def chapter_files(path, chapter)
      dir = File.dirname(File.expand_path(path))
      same_stem = File.join(dir, "#{File.basename(path, EXAMPLES_EXTENSION)}.bluebook")
      return [same_stem] if File.file?(same_stem)

      Dir.glob([File.join(dir, "*.bluebook"), File.join(dir, "bluebook", "*.bluebook")])
         .select { |file| chapter_name(file) == chapter }
    end

    # Declares the chapter a sentence-form file holds, in the registry now current.
    #
    # The Ruby text is loaded from a file of its own, because a predicate's source is recovered
    # from the file it was written in; the registry then records the sentence file as the
    # chapter's source, not the generated one.
    #
    # @param path [String] a sentence-form `.bluebook`
    # @return [void]
    def load(path)
      generated = write_generated(path, ruby_text(path))
      Kernel.load(generated)
      point_sources_at(generated, path)
    end

    # Makes the registry record the sentence file `path` as the source of what `generated` declared.
    #
    # @param generated [String] the rendered file that was loaded
    # @param path [String] the sentence file it came from
    # @return [void]
    def point_sources_at(generated, path)
      registry = Hecks.current_registry
      registry.bluebook_sources.each_value do |paths|
        paths.map! { |source| source == generated ? path : source }
      end
    end

    # Writes rendered text where Ruby can load it, named by what the text holds so an unchanged
    # file is written once.
    #
    # @param path [String] the sentence file the text was rendered from
    # @param text [String] the rendered Ruby text
    # @return [String] the generated file's path
    def write_generated(path, text)
      dir = CacheDir.path("sentence_form")
      FileUtils.mkdir_p(dir)
      generated = File.join(dir, "#{File.basename(path, ".bluebook")}-#{Digest::SHA256.hexdigest(text)[0, 16]}.bluebook")
      File.write(generated, text) unless File.exist?(generated)
      generated
    end

    # @return [String] the path to `hecks-parse`: `HECKS_PARSE_BIN`, then the release or debug
    #   build under `rust/parser/target/`, then one on the `PATH`
    # @raise [ParserMissing] if none exists
    def binary
      candidates = [ENV.fetch("HECKS_PARSE_BIN", nil)] +
                   %w[release debug].map { |profile| File.join(ROOT, "rust/parser/target/#{profile}/hecks-parse") } +
                   ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).map { |dir| File.join(dir, "hecks-parse") }
      candidates.compact.find { |path| File.executable?(path) && !File.directory?(path) } or
        raise ParserMissing, "hecks-parse is not built — run `cargo build --release " \
                             "--manifest-path rust/parser/Cargo.toml`, or set HECKS_PARSE_BIN"
    end
  end
end
