# frozen_string_literal: true

require "hecks/hecks/adapters/console_capture"
require "hecks/hecks/adapters/claude_executable"
require "hecks/hecks/adapters/claude_resolving_shell"
require "hecks/hecks/adapters/claude_session_listing"
require "hecks/hecks/adapters/claude_resumption"

module Hecks
  module Adapters
    # The `Rousing` port's adapter for `Message`: wakes the session that holds a message's role
    # name, the ClaudeSession wake.
    #
    # Mail is addressed to a role, never a session id: the holder is the listed session whose name
    # is the role, alone or followed by a separator and no further word (`orchestrator 2`). A busy
    # holder is left alone, since its inbox hook hands the mail over at its next tool call; an idle
    # one is resumed with a line telling it to read its inbox. It writes nothing else, and refuses
    # by name when no session holds the role.
    class RoleRouser
      # No listed session holds the role the message is addressed to.
      class Unreachable < StandardError; end

      # Listed states of a session that is not running, and so runs no hook.
      IDLE = %w[idle stopped done failed].freeze

      # @param listing [#call, nil] stand-in: answers the `claude agents` entries
      # @param resume [#call, nil] stand-in: wakes an entry given the prompt
      def initialize(listing: nil, resume: nil)
        @read = listing
        @resume = resume
      end

      # @param recipient [Hash, String] the role the message is addressed to
      # @return [Hash{Symbol => Object}] `recipient:` the role, passed back for the policy
      # @raise [Unreachable] naming the role no session holds
      def rouse(recipient:, **)
        role = recipient.is_a?(Hash) ? recipient[:value].to_s : recipient.to_s
        entry = holder(role) or raise Unreachable, "no session holds the role #{role}"
        wake(entry, role) if idle?(entry)
        { recipient: { value: role } }
      end

      # The unread fallback: resumes the holder when it is idle, and refuses by name when it works,
      # since a working session is never stopped; the next sweep tries again.
      #
      # @param recipient [Hash, String] the role the message is addressed to
      # @return [Hash{Symbol => Object}] `recipient:` the role, passed back for the policy
      # @raise [Unreachable] naming the role no idle session holds
      def resume(recipient:, **)
        role = recipient.is_a?(Hash) ? recipient[:value].to_s : recipient.to_s
        entry = holder(role) or raise Unreachable, "no session holds the role #{role}"
        raise Unreachable, "the session holding #{role} is working" unless idle?(entry)

        wake(entry, role)
        { recipient: { value: role } }
      end

      private

      def holder(role)
        entries.select { |entry| entry["name"].to_s.match?(/\A#{Regexp.escape(role)}(?:\z|[\s:_-]+(?![A-Za-z]))/i) }
               .max_by { |entry| busy?(entry) ? 1 : 0 }
      end

      def busy?(entry) = entry["status"].to_s == "busy" || %w[working blocked].include?(entry["state"].to_s)

      def idle?(entry) = !busy?(entry) && IDLE.include?(entry["state"].to_s.then { |s| s.empty? ? "idle" : s })

      def wake(entry, role)
        prompt = "You have mail for #{role}: read it with exe/hecks agents Message.inbox recipient.value=#{role}"
        @resume ? @resume.call(entry, prompt) : resume_session(entry, prompt)
      end

      def resume_session(entry, prompt)
        shell = ClaudeResolvingShell.new(executable: ClaudeExecutable.new(candidates: ClaudeExecutable::CANDIDATES))
        ClaudeResumption.new(ClaudeExecutable::COMMAND, shell)
                        .call(entry["id"].to_s, entry, prompt, env: {}, chdir: Dir.pwd)
      end

      def entries = @read ? @read.call : listing.entries

      def listing
        shell = ClaudeResolvingShell.new(executable: ClaudeExecutable.new(candidates: ClaudeExecutable::CANDIDATES))
        ClaudeSessionListing.new(ClaudeExecutable::COMMAND, shell: shell)
      end
    end
  end
end
