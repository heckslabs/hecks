# frozen_string_literal: true

require "json"

module Hecks
  module Adapters
    class GitLanding
      # The one landing in flight in a repository, kept as a claim file under the main checkout's
      # git directory so it holds across processes.
      #
      # A claim is made by creating the file with `File::EXCL`, which exactly one of any number of
      # concurrent attempts wins, inside an `flock` that lets a stale claim be replaced without two
      # attempts both replacing it. The claim names the branch, the process and the time. A claim
      # older than the stale window belongs to a landing that never finished and is superseded;
      # the new claim says so.
      class InFlight
        # Raised when a fresh claim is already held; the message names the holder.
        class Busy < RuntimeError; end

        # The minutes after which a claim is taken to be abandoned, when no setting names another.
        DEFAULT_STALE_MINUTES = 30

        # What a successful claim holds.
        #
        # @!attribute [r] token
        #   @return [String] identifies this claim, so only its holder can release it
        # @!attribute [r] superseded
        #   @return [String, nil] the sentence naming the abandoned landing this claim replaced
        Claim = Struct.new(:token, :superseded)

        # @param git_dir [String] the main checkout's git directory
        # @param stale_minutes [Numeric, nil] the stale window; the default when nil
        # @param clock [#call] answers the current Time
        def initialize(git_dir, stale_minutes: nil, clock: -> { Time.now })
          @path = File.join(git_dir, "hecks-landing.claim")
          @guard = File.join(git_dir, "hecks-landing.guard")
          @stale = (stale_minutes || DEFAULT_STALE_MINUTES).to_f * 60
          @clock = clock
        end

        # Claims the queue for a branch.
        #
        # @param branch [String] the branch being landed
        # @return [Claim] the claim to release, with the supersession it made if any
        # @raise [Busy] naming the branch in flight and how long, when a fresh claim is held
        def claim(branch)
          guarded do
            held = current
            raise Busy, "#{wording(held)} is in flight" if held && !stale?(held)

            File.delete(@path) if held
            write(branch, held && "superseded the abandoned landing of #{wording(held)}")
          end
        end

        # Frees the queue, only when the claim is still the one held.
        #
        # @param claim [Claim] what {#claim} answered
        # @return [void]
        def release(claim)
          guarded do
            held = current
            File.delete(@path) if held && held[:token] == claim.token
          end
        end

        private

        def write(branch, superseded)
          token = "#{Process.pid}-#{rand(36**8).to_s(36)}"
          File.open(@path, File::WRONLY | File::CREAT | File::EXCL) do |file|
            file.write(JSON.generate(token: token, branch: branch, pid: Process.pid, at: @clock.call.to_f))
          end
          Claim.new(token, superseded)
        end

        def guarded
          File.open(@guard, File::RDWR | File::CREAT) do |file|
            file.flock(File::LOCK_EX)
            yield
          end
        end

        def current
          return unless File.exist?(@path)

          JSON.parse(File.read(@path), symbolize_names: true)
        rescue JSON::ParserError
          { branch: "another landing", at: File.mtime(@path).to_f }
        end

        def stale?(held) = age(held) > @stale

        def age(held) = @clock.call.to_f - held[:at].to_f

        def wording(held)
          minutes = (age(held) / 60).floor
          "#{held[:branch]} (landing for #{minutes} minute#{"s" unless minutes == 1})"
        end
      end
    end
  end
end
