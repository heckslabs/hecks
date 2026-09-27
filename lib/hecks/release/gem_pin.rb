require_relative "gem_pin/published_versions"

module Hecks
  module Release
    # Finds the hecks version a project runs on, and refuses one that a
    # stranger could not install.
    #
    # ## Why it exists
    #
    # A project that is copied out of its own workspace (handed to someone who
    # will `bundle install` it, or built in an image with no sibling checkout)
    # has to name a hecks release RubyGems actually publishes. A `path:` or
    # `git:` source only works where the path or remote is reachable, and a
    # version that was never published resolves nowhere. This reads the
    # project's Gemfiles and lockfiles, without running Bundler, and says which
    # version each pins or refuses.
    #
    # ## Resolution
    #
    # For each `Gemfile` under the root (a project can hold several, such as a
    # domain and a helper app) the pin is, in order: the version its
    # `Gemfile.lock` resolved, or the newest stable release its version
    # constraint allows. Each pin must be published; the Gemfiles need not
    # agree.
    #
    # ## Injectable network
    #
    # The published list comes from `published:`, any object answering
    # `include?(version)` and `newest_satisfying(requirement)`. The default asks
    # RubyGems; a caller without network hands in its own.
    class GemPin
      GEM_LINE = /^\s*gem\s+["']hecks["'](?<rest>.*)$/
      SOURCE_OPTION = /\b(?:path|git|github|gitlab|bitbucket|branch|ref|tag):/
      LOCKED = /^    hecks \((?<version>[^)]+)\)/

      # What `resolve` found.
      #
      # @!attribute [r] version
      #   @return [String] the newest pin
      # @!attribute [r] pins
      #   @return [Hash{String => String}] each Gemfile that declares hecks, relative to the
      #     root, mapped to the version it runs on
      Resolved = Struct.new(:version, :pins, keyword_init: true)

      # @param published [#include?, #newest_satisfying] the source of published versions
      def initialize(published: PublishedVersions.new)
        @published = published
      end

      # Resolves the hecks versions the project in `root` runs on.
      #
      # @param root [String] the project's root directory
      # @return [Resolved] the newest pin and every pin
      # @raise [Error] if no Gemfile declares hecks, one takes it from a source other than
      #   RubyGems, one pins a version RubyGems does not publish, or a constraint allows
      #   no published release
      def resolve(root)
        pins = gemfiles(root).filter_map { |gemfile| pin_for(gemfile, root) }.to_h
        raise Error, "no Gemfile declares the hecks gem, so this is not a Hecks project" if pins.empty?

        pins.each do |rel, version|
          raise Error, "hecks #{version} is not published on RubyGems (#{rel})" unless @published.include?(version)
        end
        Resolved.new(version: pins.values.max_by { |version| Gem::Version.new(version) }, pins: pins)
      end

      private

      def gemfiles(root)
        Dir.glob("**/Gemfile", base: root).reject { |rel| rel.include?("node_modules/") }.sort
           .map { |rel| File.join(root, rel) }
      end

      def pin_for(gemfile, root)
        declaration = File.read(gemfile).match(GEM_LINE) or return nil
        rel = gemfile.delete_prefix("#{root}/")
        if (source = declaration[:rest][SOURCE_OPTION])
          raise Error, "#{rel} takes hecks from `#{source}`, not from RubyGems; the project must use a published version"
        end

        [rel, locked_version(gemfile, rel) || newest_allowed(declaration[:rest], rel)]
      end

      # The version Gemfile.lock resolved, if there is a lockfile. A hecks
      # entry under `PATH` or `GIT` means the lockfile is not installable either.
      def locked_version(gemfile, rel)
        lock = "#{gemfile}.lock"
        return nil unless File.exist?(lock)

        text = File.read(lock)
        refuse_unpublished_source!(text, rel)
        text.match(LOCKED)&.[](:version)
      end

      def refuse_unpublished_source!(lock_text, rel)
        lock_text.split("\n\n").each do |section|
          next unless section.start_with?("PATH", "GIT") && section.match?(LOCKED)

          raise Error, "#{rel}.lock resolves hecks from a #{section.lines.first.strip} source, not from RubyGems"
        end
      end

      def newest_allowed(rest, rel)
        constraints = rest.scan(/["']([^"']+)["']/).flatten.grep(/\A\s*(?:[~><=!]+\s*)?\d/)
        version = @published.newest_satisfying(Gem::Requirement.new(*constraints))
        raise Error, "no published hecks release satisfies the constraint in #{rel}" unless version

        version.to_s
      end
    end
  end
end
