# frozen_string_literal: true

require "hecks"
require_relative "../tools"

module Hecks
  module Tools
    # Projects each domain's OIDC client and scope manifest (`Hecks::Projections::OIDC`) into an
    # `oidc.json` beside the domain.
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

      # @param root [String] the checkout
      # @param path [String] a domain directory, relative to `root`
      # @return [void]
      def project(root, path)
        runtime = Hecks.boot(File.join(root, path), install_doors: false)
        name    = runtime.registry.bluebooks.keys.first
        return warn("  #{path}: no bluebook found — skipped") unless name

        write_manifest(runtime.registry, name, File.join(root, path, "oidc.json"))
        puts "  #{path}/oidc.json  <-  #{name}"
      rescue StandardError => e
        warn "  #{path}: cannot project — #{e.message.lines.first.strip}"
      end

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
