require_relative "../../hecks"

module Hecks
  module Tools
    # The tool behind `hecks regeneration_run.project_glossary!`: boots a domain and projects one
    # bluebook into its Ubiquitous Language glossary, `glossary.md` plus `html/index.html` rendered
    # from it, in the domain's own `glossary/` folder. With `--check` it writes nothing and names
    # each committed file that differs from the projection.
    #
    # A field the deployment marks sensitive (`has_phi(readable_by:)` in the domain's `.hecksagon`)
    # is tagged in the glossary with its category. spec/glossary_spec.rb re-projects every one and
    # refuses a diff, so a committed glossary never lags the bluebook it describes.
    module ProjectGlossary
      # The line printed when an argument is missing.
      USAGE = "usage: hecks regeneration_run.project_glossary! domain.value=<path> bluebook.value=<Name> [--confirm]".freeze

      module_function

      # Runs the tool as a program's whole body: writes the glossary, or with `--check` compares it.
      #
      # @param argv [Array<String>] the domain path, the bluebook's name, and `--check` to compare
      # @param root [String] the checkout; the domain path is read from where the caller stands
      # @return [Integer] 0 when the glossary was written or is current, 1 when a check finds drift
      # @raise [SystemExit] with the usage line when an argument is missing
      def main(argv, root: Tools::ROOT)
        words = argv - ["--check"]
        domain, declaration_name = words
        abort USAGE unless domain && declaration_name

        path = File.expand_path(domain, root)
        return check_glossary(path, declaration_name) if argv.include?("--check")

        report_written(write_glossary(path, declaration_name))
      end

      # @api private
      # @return [Integer] 0, after printing each file written
      def report_written(written)
        warn "wrote #{written.size} file(s):"
        written.each { |path| puts "  #{path}" }
        0
      end

      # @api private
      # @return [Integer] 0 when every committed file is the projection, 1 naming each that is not
      def check_glossary(domain, declaration_name)
        drifted = drift(domain, declaration_name)
        if drifted.empty?
          puts "the glossary under #{domain} is current"
          return 0
        end

        warn "#{drifted.size} glossary file(s) under #{domain} drifted; add --confirm to rewrite:"
        drifted.each { |path| warn "  #{path}" }
        1
      end

      # @api private
      # @return [Array<String>] the files under `glossary/` that are missing or differ from the
      #   projection, relative to that folder
      def drift(domain, declaration_name)
        projection(domain, declaration_name).reject do |relative, text|
          path = File.join(domain, "glossary", relative)
          File.exist?(path) && File.read(path, encoding: "UTF-8") == text
        end.keys
      end

      # @api private
      # @return [Array<String>] the files written under the domain's `glossary/` folder
      def write_glossary(domain, declaration_name)
        Projector.write(projection(domain, declaration_name), File.join(domain, "glossary"), as: :files)
      end

      # @api private
      # @return [Hash{String => String}] each glossary file's path under `glossary/` and its text
      def projection(domain, declaration_name)
        runtime = Hecks.boot(domain)
        declaration = runtime.bluebook(declaration_name)
        Projector.call(:glossary, bluebook: declaration, options: { markings: markings_for(runtime, declaration_name) })
      end

      # The privacy markings the deployment declared for fields of one bluebook.
      #
      # @api private
      def markings_for(runtime, declaration_name)
        runtime.pending_privacy_markings.select do |marking|
          marking[:domain].to_s.start_with?("#{declaration_name}::")
        end
      end
    end
  end
end
