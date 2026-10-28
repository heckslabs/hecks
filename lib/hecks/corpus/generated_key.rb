# frozen_string_literal: true

require "digest"

module Hecks
  module Corpus
    # A content hash of everything that decides what `hecks regenerate_corpus` writes for some of
    # the corpus's domains: the generator, and each named domain's own sources. A job that reads a
    # few domains of the generated tree keys its cache on those, so a change to any other domain
    # leaves its cache where it was.
    #
    # The hash reads file contents only, never a time, and only tracked files: a bare checkout and
    # one that has already regenerated hash the same. It errs wide, never narrow: a file that might
    # be read is hashed, so a key can move for a change that did not matter, and never stay put for
    # one that did.
    #
    #   Hecks::Corpus::GeneratedKey.key(%w[lease_clock nested_pieces])  # => "9c1e..."
    module GeneratedKey
      # Bumped when what the key hashes changes shape, so every saved entry stops matching.
      VERSION = "1"

      # What the generator is made of, relative to the checkout: the Rust crates it runs, and the
      # Ruby that builds the IR it reads. Every domain's output depends on all of it.
      GENERATOR_INPUTS = %w[
        rust/codegen/**/* rust/build/**/* rust/parser/**/* rust/Cargo.toml rust/src/generated/mod.rs
        lib/hecks/rust_build/**/* lib/hecks/projector/**/* lib/hecks/corpus/**/* lib/hecks/corpus.rb
        lib/hecks/tools/regeneration_run.rb lib/hecks/tools/regeneration_run/**/*
        lib/hecks/bluebook/**/* lib/hecks/language/**/*
        lib/hecks/runtime/**/* lib/hecks/ports/**/* lib/hecks/rust_format.rb rust-toolchain.toml Gemfile.lock
        lib/hecks/*.rb lib/hecks/grammar/**/* lib/hecks/literal/**/*
        lib/hecks/adapters/driven/*.adapter lib/hecks/adapters/driven/folder*
      ].freeze

      # The generated modules a checkout commits (rust/.gitignore ignores the rest). The cache saves
      # and restores the whole generated tree, these among it, so what is committed is hashed into
      # every key: a restored entry then never overwrites them with another commit's.
      COMMITTED_OUTPUT = %w[pizzas].freeze

      # Every bluebook, hecksagon, world and adapter file of the gem: what a domain that attaches a
      # chapter this key cannot name exactly is hashed against.
      ALL_CHAPTER_FILES = %w[lib/hecks/**/*.bluebook lib/hecks/**/*.hecksagon lib/hecks/**/*.world
                             lib/hecks/**/adapters/*.adapter].freeze

      # The one way a hecksagon attaches a gem chapter or a vendored package, which this key can
      # follow exactly.
      ATTACHES_LINE = /\A\s*attaches\s+"(?<name>\w+)"(?<vendored>,\s*from:\s*:vendor)?\s*(?:#.*)?\z/

      # Any other line that names an attachment, which this key cannot follow: it hashes wide.
      ATTACHMENT_WORD = /\battaches\b|Chapters\.|FrameworkBluebooks\.|\battach!|Framework\.load!/

      # The files a hecksagon's own text can name an attachment in.
      ATTACHING_FILES = /\.(hecksagon|world|adapter)\z/

      # The directory of the gem's Ruby, which a chapter's absolute path is read relative to.
      GEM_LIB = File.expand_path("..", __dir__).freeze

      # Raised inside this module when an attachment cannot be followed to the files it reads.
      class Unresolved < StandardError; end

      module_function

      # The key of the generated output of the named domains.
      #
      # @param names [Array<String>, nil] feature names; nil names every domain
      # @param root [String] the checkout
      # @return [String] the hex digest
      # @raise [UnknownDomain] when a name is not a domain, listing the valid ones
      def key(names = nil, root: ROOT)
        digest(listing(names, root: root))
      end

      # @param lines [Array<String>] the rows of `listing`
      # @return [String] the hex digest the rows add up to
      def digest(lines) = Digest::SHA256.hexdigest("generated-key-#{VERSION}\n#{lines.join("\n")}")

      # What `hecks corpus_run.generated_key` answers: the key, with each file hashed above it when
      # they are asked for.
      #
      # @param names [Array<String>, nil] feature names; nil names every domain
      # @param files [Boolean] whether to list each file hashed, with its own digest
      # @param root [String] the checkout
      # @return [String] the lines
      # @raise [UnknownDomain] when a name is not a domain, listing the valid ones
      def report(names = nil, files: false, root: ROOT)
        rows = listing(names, root: root)
        [*(rows if files), digest(rows)].join("\n")
      end

      # Each file the key hashes, with its own digest, so a reviewer can see why a key moved.
      #
      # @param names [Array<String>, nil] feature names; nil names every domain
      # @param root [String] the checkout
      # @return [Array<String>] `"<sha256>  <path>"` rows, sorted by path
      # @raise [UnknownDomain] when a name is not a domain, listing the valid ones
      def listing(names = nil, root: ROOT)
        files(names, root: root).map { |path| "#{Digest::SHA256.file(File.join(root, path)).hexdigest}  #{path}" }
      end

      # @param names [Array<String>, nil] feature names; nil names every domain
      # @param root [String] the checkout
      # @return [Array<String>] the paths the key hashes, relative to the checkout, sorted
      # @raise [UnknownDomain] when a name is not a domain, listing the valid ones
      def files(names = nil, root: ROOT)
        domains = Corpus.rust_domains_named(names, root: root)
        (generator_files(root) + domains.flat_map { |domain| domain_files(domain, root) }).uniq.sort
      end

      # @return [Array<String>] the generator's files that exist, and the committed generated output
      def generator_files(root)
        globs = GENERATOR_INPUTS + COMMITTED_OUTPUT.map { |feature| "rust/src/generated/#{feature}/**/*" }
        globs.flat_map { |glob| expand(glob, root) }
      end

      # One domain's own directory and every chapter it attaches.
      #
      # @param domain [RustDomain] the domain
      # @param root [String] the checkout
      # @return [Array<String>] the paths, relative to the checkout
      def domain_files(domain, root)
        own = expand("#{domain.dir.delete_prefix("#{root}/")}/**/*", root)
        own + attached_files(own, root)
      end

      # The files of every chapter the domain's own hecksagons attach, followed through the ports
      # and adapters a chapter ships. A chapter this cannot follow exactly widens to all of them.
      #
      # @param own [Array<String>] the domain's own files, relative to the checkout
      # @param root [String] the checkout
      # @return [Array<String>] the chapter files, relative to the checkout
      def attached_files(own, root)
        follow(names_in(own, root).uniq, root)
      rescue Unresolved
        ALL_CHAPTER_FILES.flat_map { |glob| expand(glob, root) }
      end

      # @param path [String] a hecksagon, world or adapter file, relative to the checkout
      # @param root [String] the checkout
      # @return [Array<String>] the gem chapters it attaches, by name
      # @raise [Unresolved] when it names an attachment in a way this does not follow
      def attached_names(path, root)
        File.readlines(File.join(root, path), chomp: true, encoding: "UTF-8").filter_map do |line|
          next if line.strip.start_with?("#") || !line.match?(ATTACHMENT_WORD)

          match = ATTACHES_LINE.match(line) or raise Unresolved, "#{path}: #{line.strip}"
          match[:name] unless match[:vendored]
        end
      end

      # Every file of the named chapters and of the chapters their own hecksagons attach.
      #
      # @param pending [Array<String>] chapter names still to read
      # @param root [String] the checkout
      # @return [Array<String>] the files, relative to the checkout
      # @raise [Unresolved] when a chapter is not one the gem carries
      def follow(pending, root)
        files = []
        seen = []
        while (name = pending.shift)
          next if seen.include?(name)

          seen << name
          files.concat(chapter = chapter_paths(name, root))
          pending.concat(names_in(chapter, root))
        end
        files
      end

      # @param paths [Array<String>] files relative to the checkout
      # @param root [String] the checkout
      # @return [Array<String>] the chapters the hecksagons, worlds and adapters among them attach
      # @raise [Unresolved] when one names an attachment in a way this does not follow
      def names_in(paths, root)
        paths.grep(ATTACHING_FILES).flat_map { |path| attached_names(path, root) }
      end

      # @param name [String] a chapter's name
      # @param root [String] the checkout
      # @return [Array<String>] the files attaching it reads, relative to the checkout
      # @raise [Unresolved] when the gem carries no chapter of that name
      def chapter_paths(name, root)
        require_relative "../framework_bluebooks"
        FrameworkBluebooks.files_of(name).map do |path|
          raise Unresolved, "#{name}: #{path} is outside the gem" unless path.start_with?("#{GEM_LIB}/")

          relative = File.join("lib/hecks", path.delete_prefix("#{GEM_LIB}/"))
          File.file?(File.join(root, relative)) ? relative : nil
        end.compact
      rescue Runtime::WiringError => e
        raise Unresolved, e.message
      end

      # The files a glob finds, relative to the checkout: no directory, and nothing under a Cargo
      # `target`, which a build fills and a bare checkout does not have.
      #
      # @param glob [String] a glob, relative to the checkout
      # @param root [String] the checkout
      # @return [Array<String>] the paths
      def expand(glob, root)
        Dir.glob(glob, File::FNM_DOTMATCH, base: root).select do |path|
          File.file?(File.join(root, path)) && !path.split("/").include?("target") && File.basename(path) != ".DS_Store"
        end
      end
    end
  end
end
