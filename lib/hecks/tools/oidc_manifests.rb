# frozen_string_literal: true

require "hecks"
require_relative "../tools"

module Hecks
  module Tools
    # Projects each domain's OIDC client and scope manifest (`Hecks::Projections::OIDC`) into an
    # `oidc.json` beside the domain, or into one `<chapter>.oidc.json` for each chapter of a
    # directory that holds several.
    #
    # A domain that has no bluebook is skipped and one that cannot be projected is reported, so a
    # sweep over the whole checkout carries on past either. `hecks deploy
    # oidc_manifest.project_oidc` writes through `Hecks::Projections::OIDC.render`, which spells an
    # empty list `[]` whichever json release is loaded, so the text does not depend on the machine.
    module OidcManifests
      # Directories that hold a `.hecksagon` but are never domains.
      NOT_DOMAINS = %r{\A(rust|deploy|tmp|coverage)/}

      module_function

      # Projects the manifests and prints one line for each domain.
      #
      # @param argv [Array<String>] domain directories, relative to `root`; every domain of the
      #   checkout when empty
      # @param root [String] the checkout
      # @return [Integer] 0
      def main(argv, root: Tools::ROOT)
        wanted = argv.empty? ? domains(root) : argv.map { |path| path.delete_prefix("#{root}/").chomp("/") }
        wanted.each { |path| project(root, path) }
        0
      end

      # Every `.hecksagon` names a domain root; rust/, deploy/, tmp/ and coverage/ are never
      # domains.
      #
      # @param root [String] the checkout
      # @return [Array<String>] the domain directories, relative to `root`, sorted
      def domains(root)
        folder = Hecks::Adapters::Folder.new
        Dir.glob(File.join(root, "**/*.hecksagon"))
           .map { |path| folder.domain_root(File.dirname(path)) }
           .compact
           .map { |path| path.delete_prefix("#{root}/") }
           .grep_v(NOT_DOMAINS)
           .uniq.sort
      end

      # Projects one manifest for each chapter the directory holds.
      #
      # @param root [String] the checkout
      # @param path [String] a domain directory, relative to `root`
      # @return [void]
      def project(root, path)
        registry = Hecks.boot(File.join(root, path), install_driving: false).registry
        return warn("  #{path}: no bluebook found — skipped") if registry.bluebooks.empty?

        project_chapters(registry, root, path)
      rescue StandardError => e
        warn "  #{path}: cannot project — #{e.message.lines.first.strip}"
      end

      # The chapters a directory declares: those with a `.bluebook` file under it. A chapter it
      # only attaches (Governance, for one) is loaded from elsewhere and has its own directory's
      # manifest.
      #
      # @param registry [Hecks::Runtime::Registry] the booted registry of the directory
      # @param directory [String] the directory that was booted
      # @return [Array<String>] the chapter names, in load order; the first loaded when none has a
      #   recorded source
      def chapters_of(registry, directory)
        under = "#{File.expand_path(directory)}/"
        own = registry.bluebooks.keys.select do |name|
          Array(registry.bluebook_sources[name]).any? { |source| File.expand_path(source).start_with?(under) }
        end
        own.empty? ? registry.bluebooks.keys.first(1) : own
      end

      # @param registry [Hecks::Runtime::Registry] the booted registry of the directory
      # @param root [String] the checkout
      # @param path [String] the domain directory, relative to `root`
      # @return [void]
      def project_chapters(registry, root, path)
        names = chapters_of(registry, File.join(root, path))
        names.each do |name|
          file = file_for(names, name)
          write_manifest(registry, name, File.join(root, path, file))
          puts "  #{path}/#{file}  <-  #{name}"
        end
      end

      # A domain of one chapter keeps `oidc.json`; a directory of several chapters, such as the
      # framework members, gets one manifest each, so none of them stands for the others.
      #
      # @param names [Array<String>] every chapter the directory holds
      # @param name [String] the chapter the manifest is for
      # @return [String] the manifest's file name: `oidc.json`, or `<chapter>.oidc.json`
      def file_for(names, name) = names.one? ? "oidc.json" : "#{Naming.snake(name)}.oidc.json"

      # @param registry [Hecks::Runtime::Registry] the booted registry
      # @param name [String] the bluebook to project
      # @param out [String] where the manifest goes
      # @return [void]
      def write_manifest(registry, name, out)
        File.write(out, Hecks::Projections::OIDC.render(Hecks::Projector.call(:oidc, bluebook: registry.bluebook(name))))
      end
    end
  end
end
