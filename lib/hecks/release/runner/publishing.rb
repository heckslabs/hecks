module Hecks
  module Release
    class Runner
      # The publish half of a release: what to publish, the confirmation, and the gem and npm
      # steps. Included in `Runner`.
      module Publishing
        private

        def publish(facts, pending)
          if pending.empty?
            @console.say("Nothing to publish for #{facts.version}.")
            @verified = registries_list?(facts.version, in_scope) unless @options.dry_run
            return 0
          end
          run_steps(facts.version, pending)
        end

        # What pushing the tag sets off, for the tag question; nothing when CI publishes nothing.
        def tag_note(version, pending)
          return unless ci_publishes?(pending)

          "CI then publishes @hecks/client #{version} to npm from the tag, which cannot be undone"
        end

        def publish_confirmed?(version, pending)
          targets = []
          targets << "hecks #{version} to rubygems.org" if pending.include?(:gem)
          targets << "@hecks/client #{version} to npm" if pending.include?(:npm) && @options.npm_local?
          return true if targets.empty?

          suffix = ci_publishes?(pending) ? " (CI then publishes @hecks/client from the tag)" : ""
          @console.confirm?("Publish #{targets.join(" and ")}#{suffix}? This cannot be undone.")
        end

        def run_steps(version, pending)
          dry_run = @options.dry_run
          publish_gem(version, dry_run) if pending.include?(:gem)
          return 1 if pending.include?(:npm) && !publish_npm!(version, dry_run, ci_publishes?(pending))

          @verified = registries_list?(version, pending) unless dry_run

          @console.say(dry_run ? "Dry run complete; nothing was tagged, pushed or published." : "Released hecks #{version}.")
          0
        end

        def publish_gem(version, dry_run)
          GemPublisher.new(root: @root, commands: @commands, console: @console).publish!(version, dry_run: dry_run)
          @steps << :gem unless dry_run
        end

        # Asks each registry a step published to whether it now lists the version.
        def registries_list?(version, pending)
          (!pending.include?(:gem) || @published.gem?(version)) && (!pending.include?(:npm) || @published.npm?(version))
        rescue Refusal
          false
        end

        def publish_npm!(version, dry_run, via_ci)
          return wait_for_ci!(version, dry_run) if via_ci

          NpmPublisher.new(root: @root, commands: @commands, console: @console).publish!(version, dry_run: dry_run)
          @steps << :npm unless dry_run
          true
        rescue CommandFailed => e
          warn_npm_failed(e, dry_run)
          raise
        end

        def warn_npm_failed(error, dry_run)
          @console.warn("npm publish failed: #{error.message}")
          return if dry_run

          @console.warn("Finish the release with: hecks publish --npm-only --npm-local --confirm " \
                        "(published steps are not repeated)")
        end

        def wait_for_ci!(version, dry_run)
          arrived = @ci.wait!(version, dry_run: dry_run, wait: @options.wait?)
          @steps << :npm if arrived && !dry_run
          @console.warn(CiPublisher.timeout_hint(version)) unless arrived
          arrived
        end
      end
    end
  end
end
