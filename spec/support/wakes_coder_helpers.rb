# What the plan-review wake specs drive: coder runs waiting on Work items, an architect review
# of one of them, and a fake runner standing in for `claude`'s resume that records which run it
# was asked to wake.
module WakesCoderHelpers
  def fake_runner(log)
    allow(Hecks::Adapters::ClaudeAgents).to(receive(:new).and_wrap_original do |original, **context|
      original.call(**context, settings: { jobs: File.join(scratch, "jobs"), settle: 0 }).tap do |agents|
        allow(agents).to(receive(:resume)) do |**held|
          log << held
          { resumed_at: { value: Time.now.utc.iso8601 }, session: { value: "stand-in-session" } }
        end
      end
    end)
  end

  def launch(*argv) = Hecks::Adapters::Driving::CliRunner.call(runtime: @hecks, argv: argv, program: "hecks")

  def wait_as_coder(work)
    launch("agent_run.dispatch!", "run.value=#{work}", "repo.value=#{scratch}", "brief.value=build", "agent.value=coder",
           "work.value=#{work}", "--wait")
  end

  def request_review(work)
    launch("agents", "PlanReview.request!", "run.value=r-#{work}", "work.value=#{work}", "hops.value=1",
           "role.value=architect", "repo.value=#{scratch}", "plan.value=plan", "--wait")
  end

  def architect_closes(work, verdict)
    state = { state: "done", detail: "reviewed", output: { result: verdict } }
    File.write(File.join(scratch, "jobs", "stand-in-session", "state.json"), JSON.generate(state))
    launch("agent_run.check!", "to=r-#{work}", "--wait")
  end

  # The architect has said its verdict and gone idle: the job still reads `working`, as it did for
  # a session that never exited, and the listing says `idle`.
  def architect_idles(work, verdict, status: "idle")
    state = { state: "working", output: { result: verdict } }
    File.write(File.join(scratch, "jobs", "stand-in-session", "state.json"), JSON.generate(state))
    File.write(File.join(scratch, "sessions.json"), JSON.generate([{ id: "stand-in-session", status: status }]))
    launch("agent_run.check!", "to=r-#{work}", "--wait")
  end

  # A review asked for in a repo path that is gone, so the architect's run is declined.
  def request_in_missing_repo(work)
    launch("agents", "PlanReview.request!", "run.value=r-#{work}", "work.value=#{work}", "hops.value=1",
           "role.value=architect", "repo.value=#{scratch}/gone", "plan.value=plan", "--wait")
  end

  # The review row as `PlanReview.reviews` lists it.
  def review_of(work)
    out, = launch("agents", "PlanReview.reviews")
    JSON.parse(out.to_s[/\[.*\]/m]).find { |row| row["run"] == "r-#{work}" }
  end

  def runs_woken = woken.map { |held| held.dig(:run, :value).to_s }
end
