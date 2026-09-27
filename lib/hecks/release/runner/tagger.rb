require_relative "commands"
require_relative "git"

module Hecks
  module Release
    class Runner
      # Makes sure the release tag `vX.Y.Z` is an annotated tag on the release
      # commit and is on origin, creating and pushing it only when it is missing.
      class Tagger
        # @param git [Git] the repository the release is cut from
        # @param console [Console] asks before the tag is created or pushed
        # @param dry_run [Boolean] report what would happen and change nothing
        def initialize(git:, console:, dry_run:)
          @git = git
          @console = console
          @dry_run = dry_run
        end

        # Brings the tag to the state described above, saying what it did.
        #
        # @param facts [Preflight::Facts] the version and commit being released
        # @return [Boolean] false when the person declined the question, true otherwise
        # @raise [Refusal] if the tag already points at another commit, locally or on origin
        # @raise [CommandFailed] if creating or pushing the tag fails
        def ensure!(facts)
          tag = "v#{facts.version}"
          local = local_commit(tag)
          remote = remote_commit(tag)
          refuse_elsewhere(tag, facts.sha, local: local, remote: remote)
          return true.tap { already_there(tag) } if remote
          return true.tap { preview(tag, facts.sha, local) } if @dry_run
          return false unless @console.confirm?(question(tag, facts.sha, local))

          create(tag, facts.sha) unless local
          push(tag)
          true
        end

        private

        def already_there(tag)
          @console.say("Tag #{tag} is already on origin at the release commit; skipping.")
        end

        def preview(tag, sha, local)
          @console.say("Would create annotated tag #{tag} at #{sha[0, 7]}.") unless local
          @console.say("Would push #{tag} to origin.")
        end

        def question(tag, sha, local)
          verb = local ? "Push" : "Create and push"
          "#{verb} annotated tag #{tag} at #{sha[0, 7]} to origin?"
        end

        def create(tag, sha)
          @git.run!("tag", "-a", tag, "-m", "Release #{tag.delete_prefix('v')}", sha)
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

        def local_commit(tag)
          result = @git.capture("rev-parse", "-q", "--verify", "refs/tags/#{tag}^{commit}")
          result.success? ? result.stdout.strip : nil
        end

        def remote_commit(tag)
          listing = @git.read("ls-remote", "--tags", "origin", "refs/tags/#{tag}", "refs/tags/#{tag}^{}")
          shas = listing.lines.to_h { |line| line.split.then { |sha, ref| [ref, sha] } }
          shas.fetch("refs/tags/#{tag}^{}") { shas["refs/tags/#{tag}"] }
        end
      end
    end
  end
end
