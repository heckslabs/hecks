# frozen_string_literal: true

# What the question-answerer specs drive: a coder run whose job reads blocked on a question, the
# orchestrator runs started for it, the coder's answer and the desk that caps those runs.
module QuestionAnswererHelpers
  def blocked_on(work, question)
    wait_as_coder(work)
    body = JSON.generate(state: "blocked", detail: question)
    File.write(File.join(scratch, "jobs", "stand-in-session", "state.json"), body)
    launch("agent_run.check!", "to=#{work}", "--wait")
  end

  def answerers(work = nil)
    rows = JSON.parse(launch("agent_run.running").first.to_s[/\[.*\]/m] || "[]")
    rows.select { |row| row["works_as"] == "answerer" && (work.nil? || row["work"] == work) }
  end

  # The answerer said its closing word and went idle: its job still reads `working`.
  def answerer_closes(run, report)
    File.write(File.join(scratch, "jobs", "stand-in-session", "state.json"),
               JSON.generate(state: "working", output: { result: report }))
    File.write(File.join(scratch, "sessions.json"), JSON.generate([{ id: "stand-in-session", status: "idle" }]))
    launch("agent_run.check!", "to=#{run}", "--wait")
  end

  def answer(work) = launch("agent_run.answer!", "to=#{work}", "answer.value=Take A.", "--wait")

  def desk = JSON.parse(launch("answer_desk.desks").first.to_s[/\[.*\]/m] || "[]").first.to_h
end
