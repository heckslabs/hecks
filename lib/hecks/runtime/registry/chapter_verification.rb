module Hecks
  module Runtime
    class Registry
      # Checks the chapters a boot loaded: no reserved name from outside the gem, and no two
      # unrelated packages sharing a name. Mixed into {Verification}.
      module ChapterVerification
        # The directory holding the gem's own Hecks chapter, the only place a chapter named
        # `Hecks` may be declared from.
        GEM_CHAPTER_DIR = File.expand_path("../../hecks", __dir__).freeze

        # The chapter names only the gem itself may declare (ADR 0080, section 9).
        RESERVED_CHAPTER_NAMES = %w[Hecks].freeze

        private

        # Refuses a chapter whose name is reserved unless every file that declared it sits under
        # the gem's own chapter directory. A rename is the only fix, so the message says so.
        #
        # @raise [WiringError] naming the reserved word and the offending file(s)
        def refuse_reserved_chapter_names!
          RESERVED_CHAPTER_NAMES.each do |reserved|
            next unless @declared.bluebooks.key?(reserved)

            sources = Array(@declared.bluebook_sources[reserved]).compact
            foreign = sources.reject { |path| gem_chapter_source?(path) }
            next if foreign.empty? && !sources.empty?

            raise WiringError, reserved_chapter_message(reserved, foreign)
          end
        end

        def reserved_chapter_message(reserved, foreign)
          where = foreign.empty? ? "" : " (declared in #{foreign.join(", ")})"
          "a chapter named #{reserved.inspect} is refused: #{reserved.inspect} is a reserved " \
            "word, the name of the gem's own chapter, and only the gem may declare it#{where}. " \
            "Rename the chapter (for example to your app's name) in its " \
            "`Hecks.bluebook #{reserved.inspect}` line and in its hecksagon."
        end

        # Whether `path` is a file of the gem's own chapter directory.
        def gem_chapter_source?(path)
          File.expand_path(path.to_s).start_with?("#{GEM_CHAPTER_DIR}/")
        end

        # Two packages can share a chapter name by coincidence (a stale vendored
        # fork of Governance/Identity/Deploy still on an app's load paths).
        # Intentional accumulation (several files declaring the same chapter on
        # purpose) is distinguished by package root, not file identity, and is left
        # untouched here — checked once, after every file has loaded.
        def refuse_cross_package_bluebook_merge!
          @declared.bluebook_sources.each do |name, paths|
            roots = paths.map { |path| package_root_for(path) }.uniq
            next if roots.size <= 1

            raise WiringError,
                  "#{name.inspect} is declared by more than one package: #{roots.join(" and ")} — " \
                  "these are two unrelated sources sharing a chapter name by coincidence, not one " \
                  "domain split across files, and merging their declarations into one chapter is " \
                  "almost certainly a stale/vendored copy left on the load path (paths: " \
                  "#{paths.join(", ")})"
          end
        end

        # The nearest boundary a path belongs to: a real gemspec, or a bare `vendor/`
        # component (vendored code is never "the same package" as what vendors it).
        # Falls back to the path's own directory when neither is found.
        def package_root_for(path)
          return path.to_s if path.nil?

          dir = File.dirname(File.expand_path(path))
          loop do
            return "vendor:#{dir}" if File.basename(dir) == "vendor"
            return dir if Dir.glob(File.join(dir, "*.gemspec")).any?

            parent = File.dirname(dir)
            return dir if parent == dir

            dir = parent
          end
        end
      end
    end
  end
end
