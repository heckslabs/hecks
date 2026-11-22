# frozen_string_literal: true

# What a spec of the stagger sends: a kind opened, and a start of it asked for at a given time.
module StaggerSteps
  REFUSAL = "the last start of the kind was at least its spacing ago"

  def launch(*argv) = Hecks::Adapters::Driving::CliRunner.call(runtime: @hecks, argv: argv, program: "hecks").first.to_s

  def admit(kind, at:, spacing: 30)
    launch("stagger.admit!", "to=#{kind}", "spacing.value=#{spacing}", "now.value=#{at}", "--wait")
  end

  def open_kind(kind) = launch("stagger.open!", "kind.value=#{kind}", "--wait")
end
