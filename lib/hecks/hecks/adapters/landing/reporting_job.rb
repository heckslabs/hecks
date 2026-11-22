# frozen_string_literal: true

require_relative "../delivery_library"

Hecks::Adapters::DeliveryLibrary.require("git_landing")

module Hecks
  module Adapters
    module Landing
      # The landing job that reports its own death. The vendored `GitLanding::Job` runs `Landing.carry!`
      # in a detached process and ends silently when that process dies with no outcome recorded; this
      # one, prepended to it, runs the same loop and then does two things more (ADR 0205 keeps the
      # delivery package's files unedited, so the override is here).
      #
      # A try that says "the resident went away" ran its line to an unknown end, so it is run once more
      # without the resident, once for the whole job. A job that ends without success and without
      # `BranchLanded` or `LandingRefused` in the last output records `LandingJobFault.report!`, naming
      # the branch and the last line of the output, so the Work item is planned again and no landing
      # stays silent.
      module ReportingJob
        # What a carry's output holds when its outcome was recorded: the events it lists.
        RECORDED = ['"LandingRefused"', '"BranchLanded"'].freeze

        # The retry of a carry whose resident went away, and the fault of a job with no outcome.
        # Each statement is one line: the lines are joined with `;` to pass the script to `ruby -e`.
        SCRIPT = <<~RUBY.tr("\n", ";").freeze
          require "securerandom"
          log = ARGV.pop
          launcher, flag, tries, pause, *carry = ARGV
          transient = #{GitLanding::Job::TRANSIENT.inspect}
          note = ->(line) { File.open(log, "a") { |f| f.puts("\#{Time.now.utc.strftime("%FT%TZ")} \#{line}") } }
          listen = [launcher, "Operation.follow", "domain.value=\#{flag}", "aggregate.value=RedFlag", "from_now=true", "wait=600"]
          cold = { "HECKS_NO_RESIDENT" => "1" }
          run = ->(env) { IO.popen(env, [launcher, *carry, { err: [:child, :out] }], &:read) }
          lost = false
          out = ""
          ok = false
          note.call("landing job begun (pid \#{Process.pid}): \#{carry.join(" ")}")
          tries.to_i.times do |count|
            out = run.call({})
            note.call("try \#{count + 1}: exit \#{$?.exitstatus.inspect}")
            note.call(out)
            if !$?.success? && !lost && out.include?("the resident went away")
              lost = true
              note.call("the resident went away: once more, without it")
              out = run.call(cold)
              note.call("try \#{count + 1} without the resident: exit \#{$?.exitstatus.inspect}")
              note.call(out)
            end
            break(ok = true) if $?.success?
            red = out.include?("main is red:")
            cause = transient.find { |text| out.include?(text) }
            break unless red || cause || out.include?("queue busy:")
            break note.call("gave up after \#{tries} tries: \#{cause || "the queue is busy or main is red"}") if count + 1 == tries.to_i
            system(*listen, out: File::NULL, err: File::NULL) if red
            next if red || !cause
            wait = [pause.to_f * (2**count), #{GitLanding::Job::LONGEST_PAUSE}].min
            note.call("\#{cause}: next try in \#{wait.round}s")
            sleep(wait)
          end
          recorded = #{RECORDED.inspect}.any? { |event| out.include?(event) }
          unless ok || recorded
            last = out.lines.map(&:strip).reject(&:empty?).last
            fault = "landing job ended without BranchLanded or LandingRefused: \#{last}"
            named = carry.select { |arg| arg.start_with?("branch.value=", "checkout.value=") }
            said = IO.popen(cold, [launcher, "LandingJobFault.report!", "run.value=\#{SecureRandom.uuid}", *named, "refusal.value=\#{fault}", "--wait", { err: [:child, :out] }], &:read)
            note.call("recorded the landing job fault: \#{fault}")
            note.call(said)
          end
          note.call("landing job ended")
        RUBY

        # Starts the job as the vendored one does, with this script.
        #
        # @param checkout [String] the worktree the branch is checked out in
        # @param branch [String] the branch to land
        # @param onto [String] the branch it lands on
        # @return [String] a sentence naming the job's log
        def start(checkout:, branch:, onto:)
          log = logfile(branch)
          carry = ["Landing.carry!", "checkout.value=#{checkout}", "branch.value=#{branch}", "onto.value=#{onto}",
                   "--confirm", "--wait"]
          argv = [RbConfig.ruby, "-e", SCRIPT, launcher!, flag_domain, GitLanding::Job::TRIES.to_s, @pause.to_s, *carry, log]
          @spawner.call(argv, @primary)
          "handed #{branch} to a landing job; it reports by event (BranchLanded or LandingRefused) and logs to #{log}"
        end
      end
    end
  end
end

Hecks::Adapters::GitLanding::Job.prepend(Hecks::Adapters::Landing::ReportingJob)
