# frozen_string_literal: true

require_relative "../../hecks"

module Hecks
  module CLI
    # The command behind `bin/project_oidc` and `hecks deploy project_oidc`: projects each
    # domain's OIDC client and scope manifest (`Projections::OIDC`) into an `oidc.json` beside it.
    #
    # `bundler/setup` pins the `json` gem in the script that calls this: newer releases
    # pretty-print an empty array as `[\n\n]`, a diff `spec/oidc_manifest_spec.rb` would report as
    # drift.
    module ProjectOidc
      # Build output and other trees under a root that hold no domain a caller means.
      IGNORED = %r{\A(rust|deploy|tmp|coverage)/}

      # What one domain's projection came to.
      Outcome = Struct.new(:path, :chapter, :error)

      module_function

      # Every domain under a root: each directory holding a `.hecksagon` names one.
      #
      # @param root [String] the tree searched
      # @return [Array<String>] domain directories relative to the root, sorted
      def domains(root)
        folder = Adapters::Folder.new
        Dir.glob(File.join(root, "**/*.hecksagon"))
           .map { |path| folder.domain_root(File.dirname(path)) }
           .compact
           .map { |path| path.delete_prefix("#{root}/") }
           .grep_v(IGNORED)
           .uniq.sort
      end

      # Projects the manifests.
      #
      # @param root [String] the tree the domains are under
      # @param wanted [Array<String>] domain directories to project; every domain when empty
      # @return [Array<Outcome>] one per domain: the chapter projected, or why it could not be
      def call(root:, wanted: [])
        paths = wanted.empty? ? domains(root) : wanted.map { |path| path.delete_prefix("#{root}/").chomp("/") }
        paths.map { |path| project(root, path) }
      end

      # @param root [String] the tree the domain is under
      # @param path [String] the domain directory relative to the root
      # @return [Outcome] the chapter projected, or why it could not be
      def project(root, path)
        runtime = Hecks.boot(File.join(root, path), install_facade: false)
        name = runtime.registry.bluebooks.keys.first
        return Outcome.new(path, nil, "no bluebook found — skipped") unless name

        out = File.join(root, path, "oidc.json")
        Projector.write(Projector.call(:oidc, bluebook: runtime.registry.bluebook(name)), out)
        Outcome.new(path, name, nil)
      rescue StandardError => e
        Outcome.new(path, nil, "cannot project — #{e.message.lines.first.strip}")
      end
    end
  end
end
