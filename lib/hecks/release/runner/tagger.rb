require_relative "commands"
require_relative "git"

module Hecks
  module Release
    class Runner
      # Makes sure the release tag `vX.Y.Z` is an annotated tag on the release
      # commit and is on origin, creating and pushing it only when it is missing.
      class Tagger
        def initialize(git:, console:, dry_run:)
          @git = git
          @console = console
          @dry_run = dry_run
          @changed = false
        end

        # @return [Boolean] whether this run created or pushed the tag, for real
        def changed?
          @changed
        end

        # Brings the tag to the state described above, saying what it did; returns
        # false only when the person declined the confirmation.
        #
        # @param facts [#version, #sha] the release
        # @param note [String, nil] what pushing the tag sets off, worded into the question
        def ensure!(facts, note: nil)
          tag = "v#{facts.version}"
          local = local_commit(tag)
          remote = remote_commit(tag)
          refuse_elsewhere(tag, facts.sha, local: local, remote: remote)
          return true.tap { already_there(tag) } if remote
          return true.tap { preview(tag, facts.sha, local) } if @dry_run
          return false unless @console.confirm?(question(tag, facts.sha, local, note))

          create(tag, facts.sha) unless local
          push(tag)
          @changed = true
          true
        end

        # @param tag [String] the tag, such as `v3.0.0`
        # @return [String, nil] the commit the tag points at in this checkout, or nil when absent
        def local_commit(tag)
          result = @git.capture("rev-parse", "-q", "--verify", "refs/tags/#{tag}^{commit}")
          result.success? ? result.stdout.strip : nil
        end

        # @param tag [String] the tag, such as `v3.0.0`
        # @return [String, nil] the commit the tag points at on origin, or nil when it is not there
        # @raise [Refusal] when the remote's tags cannot be listed
        def remote_commit(tag)
          listing = @git.read("ls-remote", "--tags", "origin", "refs/tags/#{tag}", "refs/tags/#{tag}^{}")
          shas = listing.lines.to_h { |line| line.split.then { |sha, ref| [ref, sha] } }
          shas.fetch("refs/tags/#{tag}^{}") { shas["refs/tags/#{tag}"] }
        end

        private

        def already_there(tag)
          @console.say("Tag #{tag} is already on origin at the release commit; skipping.")
        end

        def preview(tag, sha, local)
          @console.say("Would create annotated tag #{tag} at #{sha[0, 7]}.") unless local
          @console.say("Would push #{tag} to origin.")
        end

        def question(tag, sha, local, note)
          verb = local ? "Push" : "Create and push"
          "#{verb} annotated tag #{tag} at #{sha[0, 7]} to origin#{" (#{note})" if note}?"
        end

        def create(tag, sha)
          @git.run!("tag", "-a", tag, "-m", "Release #{tag.delete_prefix("v")}", sha)
        end

        def push(tag)
          @git.run!("push", "origin", tag)
        end

        def refuse_elsewhere(tag, sha, local:, remote:)
          { "locally" => local, "on origin" => remote }.each do |where, commit|
            next if commit.nil? || commit == sha

            raise Refusal, "tag #{tag} already points at #{commit[0, 7]} #{where}, not at the release commit " \
                           "#{sha[0, 7]}; if that tag was never released, delete it (git tag -d #{tag}; " \
                           "git push origin :refs/tags/#{tag}) and re-run, otherwise main has moved since the release " \
                           "and the missing package must be published from a checkout of #{tag}"
          end
        end
      end
    end
  end
end
