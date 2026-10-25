require "spec_helper"
require "hecks/cli"
require "open3"
require_relative "doc_banners_spec"

# A living document names things that exist: repo paths, `hecks <verb>` commands and `Hecks::`
# constants. Each is a claim the code can answer, so a rename or removal that leaves the document
# behind fails here. A document that dates itself with a banner (`DocBanners.required`) is a
# snapshot and is not read, and one that tells the history of a removed name sits in HISTORICAL.
module DocReferences
  ROOT = File.expand_path("..", __dir__)

  HISTORICAL = %w[docs/migrating-2-to-3.md].freeze

  # Words exe/hecks hands to Hecks::CLI before the launcher; they are not qualified names.
  UNQUALIFIED = (Hecks::CLI::COMMANDS.keys.map(&:to_s) + %w[console init interview version help]).freeze

  # Launchers that take a verb of their own after them: `hecks deploy recipe.project`.
  CHAPTER_LAUNCHERS = %w[query ask deploy site quality_control].freeze

  PATH_ROOTS = %w[lib spec rust examples exe docs editors].freeze
  PATH = %r{\A(?:#{PATH_ROOTS.join("|")})/[\w./-]+\z}
  PLACEHOLDER = /<|>|\*|\{|\$|N{3,}|\.\./
  WORD = /\A[a-z_]+(?:\.[a-z_]+)?\z/

  module_function

  GLOBS = %w[{README,CONTRIBUTING,CLAUDE}.md docs/*.md docs/implemented/*.md docs/implemented/guides/*.md
             rust/lsp/README.md].freeze

  def docs
    GLOBS.flat_map { |glob| Dir[File.join(ROOT, glob)] }.sort.reject { |path| skipped?(path) }
  end

  def skipped?(path)
    HISTORICAL.include?(path.delete_prefix("#{ROOT}/")) || DocBanners.required.include?(File.basename(path))
  end

  # Every inline code span of the living documents, as [document, code], fenced blocks left out.
  def claims
    @claims ||= docs.flat_map do |path|
      File.read(path).gsub(/^ *```.*?^ *```/m, "").scan(/`([^`\n]+)`/).flatten
          .map { |code| [path.delete_prefix("#{ROOT}/"), code] }
    end
  end

  # A repo path as the document writes it, or nil when the span is not one or is a pattern.
  def path_claim(code)
    token = code.strip.split(/\s+/).first.to_s.sub(/:\d+(?:-\d+)?\z/, "").sub(/#\w+\z/, "").delete_suffix("()")
    token.chomp("/") if token.match?(PATH) && !token.match?(PLACEHOLDER)
  end

  def missing_paths
    claims.filter_map do |doc, code|
      path = path_claim(code)
      "#{doc}: #{path}" if path && !File.exist?(File.join(ROOT, path))
    end.uniq
  end

  # The words a document types after `hecks`, as the launcher would be given them, or nil.
  def verb_argv(code)
    program, first, *rest = code.split(/\s+/).map { |word| word.delete_suffix("!") }
    return unless program == "hecks" && first.to_s.match?(WORD)
    return [first] unless CHAPTER_LAUNCHERS.include?(first)

    second = chapter_verb(first, rest)
    second.to_s.match?(WORD) ? [first, second] : [first]
  end

  # The verb after a launcher. A chapter's own `query` or `ask` is passed over, as the chapter's
  # launcher passes it: `hecks quality_control query sweep.create_ledger_role`.
  def chapter_verb(launcher, rest)
    asking = %w[query ask]
    asking.include?(rest.first) && !asking.include?(launcher) ? rest[1] : rest.first
  end

  # Every verb and query a launcher lists with `--all`, as `aggregate.name`.
  def listed(*launcher)
    out, = Open3.capture2e({ "HECKS_ENVIRONMENT" => "memory" }, File.join(ROOT, "exe/hecks"), *launcher, "--all",
                           chdir: ROOT)
    aggregate = nil
    out.each_line.with_object([]) do |line, names|
      aggregate = line[/\A  ([a-z_]+):\s*\z/, 1] || aggregate
      names.concat(listed_names(line, aggregate))
    end
  end

  def listed_names(line, aggregate)
    qualified = line[/\A {2,4}([a-z_]+\.[a-z_]+)!?\s{2,}\S/, 1]
    return [qualified] if qualified

    bare = line[/\A    ([a-z_]+)!?\s{2,}\S/, 1]
    return ["#{aggregate}.#{bare}"] if bare

    line.match?(/\A    (?:[a-z_]+\.[a-z_]+!?\s*)+\z/) ? line.scan(/([a-z_]+\.[a-z_]+)!?/).flatten : []
  end

  def known_verbs
    @known_verbs ||= { [] => listed + UNQUALIFIED + CHAPTER_LAUNCHERS }.merge(
      %w[deploy site quality_control].to_h { |chapter| [[chapter], listed(chapter)] }
    )
  end

  def resolves?(argv)
    launcher = argv.size == 2 && !%w[query ask].include?(argv.first) ? [argv.first] : []
    known_verbs.fetch(launcher, []).include?(argv.last) ||
      (argv.first == "query" && known_verbs[[]].include?(argv.last)) ||
      chapter_query?(argv)
  end

  # `hecks <chapter> query <name>` reads through a chapter's own launcher, so a claim that stops at
  # `query` resolves when the chapter has one.
  def chapter_query?(argv) = argv.size == 2 && argv.last == "query" && known_verbs.key?([argv.first])

  def unresolved_verbs
    by_verb = claims.each_with_object({}) do |(doc, code), found|
      argv = verb_argv(code)
      (found[argv] ||= []) << doc if argv
    end
    by_verb.reject { |argv, _| resolves?(argv) }
           .map { |argv, named_in| "hecks #{argv.join(" ")}  (#{named_in.uniq.join(", ")})" }
  end

  def constant_claim(code)
    code[/\A(Hecks(?:::[A-Z][A-Za-z0-9]*)+)(?:[.#]\w+[?!]?)?(?:\(.*\))?\z/, 1]
  end

  # Every module and class name some Ruby file under lib/ declares, for constants that load lazily
  # and so are not defined until something requires them.
  def declared_names
    @declared_names ||= Dir[File.join(ROOT, "lib/**/*.rb")].flat_map do |file|
      File.read(file).scan(/^\s*(?:class|module)\s+(?:\w+::)*(\w+)/).flatten
    end.to_set
  end

  def resolves_constant?(name)
    Object.const_get(name)
    true
  rescue NameError
    declared_names.include?(name.split("::").last)
  end

  def unresolved_constants
    claims.filter_map do |doc, code|
      name = constant_claim(code)
      "#{doc}: #{name}" if name && !resolves_constant?(name)
    end.uniq
  end
end

RSpec.describe "living documents' references" do
  it "names only repo paths that exist" do
    missing = DocReferences.missing_paths

    expect(missing).to be_empty, "paths that do not exist:\n#{missing.join("\n")}"
  end

  it "names only hecks verbs the launcher resolves", :aggregate_failures, :process do
    unresolved = DocReferences.unresolved_verbs

    expect(unresolved).to be_empty, "verbs the launcher does not resolve:\n#{unresolved.join("\n")}"
  end

  it "names only Hecks constants that resolve" do
    unresolved = DocReferences.unresolved_constants

    expect(unresolved).to be_empty, "constants that do not resolve:\n#{unresolved.join("\n")}"
  end
end
