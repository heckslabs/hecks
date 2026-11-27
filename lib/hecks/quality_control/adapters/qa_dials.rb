require "hecks/fuzzing/qa_settings"

# The QA loop's tunable dials, one constant each, read from `qa/settings.yml` by
# {Hecks::Fuzzing::QaSettings}. What each dial is and takes is declared once, as its `QaDial` row in
# the Vocabulary bluebook; `PR_CAP_PER_DAY` is the `pr_cap_per_day` dial.
#
# The dials are settings, so they live on the adapter side: the QualityControl bluebook only
# declares, and the adapters that read a dial require this file. `HECKS_QA_SETTINGS_PATH` lets a
# subprocess test read a different settings file.
module QualityControlDials
  settings = Hecks::Fuzzing::QaSettings.load(
    ENV.fetch("HECKS_QA_SETTINGS_PATH", Hecks::Fuzzing::QaSettings::DEFAULT_PATH)
  )

  Hecks::Vocabulary.rows("QaDial").each do |dial|
    const_set(dial.fetch("name").upcase, settings.public_send(dial.fetch("name")))
  end

  # The identity the loop runs as. `WaivedBy` repeats this literal (invariants read literals,
  # not constants); `spec/quality_control_spec.rb` pins the two equal.
  AUTOMATED_ENGINEER = "qa_sweep".freeze
end
