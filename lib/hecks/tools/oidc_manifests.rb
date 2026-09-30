# frozen_string_literal: true

require "hecks"
require_relative "../tools"

module Hecks
  module Tools
    # Projects each domain's OIDC client and scope manifest (`Hecks::Projections::OIDC`) into an
    # `oidc.json` beside the domain.
    #
    # A domain that has no bluebook is skipped and one that cannot be projected is reported, so a
    # sweep over the whole checkout carries on past either. `hecks deploy project_oidc` loads
    # `bundler/setup` first, which pins the `json` gem: newer releases pretty-print an empty array
    # as `[\n\n]`, a diff spec/oidc_manifest_spec.rb would report as drift.
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

        unless name
          warn "  #{path}: no bluebook found — skipped"
          return
        end

        bluebook = runtime.registry.bluebook(name)
        out      = File.join(root, path, "oidc.json")

        Hecks::Projector.write(Hecks::Projector.call(:oidc, bluebook: bluebook), out)
        puts "  #{path}/oidc.json  <-  #{name}"
      rescue StandardError => e
        warn "  #{path}: cannot project — #{e.message.lines.first.strip}"
      end
    end
  end
end
