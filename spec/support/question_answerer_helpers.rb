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

  # The coder's session ended: its job reads `done`, and the check records the end.
  def run_ends(work)
    File.write(File.join(scratch, "jobs", "stand-in-session", "state.json"), JSON.generate(state: "done"))
    launch("agent_run.check!", "to=#{work}", "--wait")
  end

  # The runs whose questions still wait on an answer, asked or seated.
  def open_questions
    rows = JSON.parse(launch("Question.open").first.to_s[/\[.*\]/m] || "[]")
    rows.map { |row| row["run"].is_a?(Hash) ? row["run"]["value"] : row["run"] }
  end

  def desk = JSON.parse(launch("answer_desk.desks").first.to_s[/\[.*\]/m] || "[]").first.to_h
end
