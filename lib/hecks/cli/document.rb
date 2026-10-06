require_relative "../../hecks"

module Hecks
  module CLI
    # The command behind `hecks docs` and `hecks narrate`:
    # one domain's document, projected from its own bluebook, to stdout.
    #
    # Nothing is written for the caller: redirect it, so git decides whether it drifted.
    module Document
      # Build output and other trees under a root that hold no domain a caller means.
      # Matched against the path relative to the root, because a substring test
      # against an absolute path tests wherever somebody happened to clone.
      IGNORED = %r{\A(rust|deploy|tmp|coverage)/}

      module_function

      # Prints `projection` for the domain and optional aggregate `argv` names.
      #
      # @param argv [Array<String>] an optional domain directory, then an optional
      #   aggregate name
      # @param projection [Symbol] `:docs` or `:narrate`
      # @param program [String] the name the usage message calls this command by
      # @param root [String] the directory whose domains are listed when no domain
      #   is found
      # @return [void]
      # @raise [SystemExit] when no domain is found, it cannot boot, it loads no
      #   bluebook, or the aggregate does not exist
      def call(argv, projection:, program:, root:)
        here = Adapters::Folder.new.domain_root
        path, aggregate = target(argv, here)
        refuse_without_domain(program, root) unless path

        bluebook = boot_bluebook(path)
        begin
          puts Projector.call(projection, bluebook: bluebook, options: aggregate ? { aggregate: aggregate } : {})
        rescue Runtime::NotFound => e
          abort e.message
        end
      end

      # The domain's own chapter, not a framework member it attached: insertion
      # order, the same distinction `Runtime::Loader.dispatcher_for` draws.
      #
      # @api private
      def boot_bluebook(path)
        begin
          runtime = Hecks.boot(path, install_doors: false)
        rescue StandardError => e
          abort "cannot read #{path}: #{e.message.lines.first.strip}"
        end

        runtime.registry.bluebooks.values.first or abort "#{path} loaded no bluebook"
      end

      # Lists every directory under `root` that `Hecks.boot` would accept.
      #
      # Found by their wiring, not their chapters: a `.hecksagon` says this is a
      # domain, while most `.bluebook` files (era translations, grammar, fixtures) are not.
      #
      # @param root [String] the directory to search under
      # @return [Array<String>] domain directory paths relative to `root`,
      #   deduplicated and sorted
      def domains(root)
        Dir.glob(File.join(root, "**/*.hecksagon"))
           .map    { |path| File.basename(File.dirname(path)) == "bluebook" ? File.dirname(path, 2) : File.dirname(path) }
           .map    { |path| path.delete_prefix("#{root}/") }
           .grep_v(IGNORED)
           .uniq.sort
      end

      # @api private
      def target(argv, here)
        if argv.empty?              then [here, nil]
        elsif argv.length > 1       then [argv[0], argv[1]]
        elsif File.directory?(argv[0]) then [argv[0], nil]
        else [here, argv[0]]
        end
      end

      # @api private
      def refuse_without_domain(program, root)
        warn "usage: #{program} [domain-path] [aggregate]"
        warn ""
        warn "No bluebook here — #{Dir.pwd} is not inside a domain. Name one:"
        domains(root).each { |candidate| warn "  #{candidate}" }
        exit 1
      end
    end
  end
end
