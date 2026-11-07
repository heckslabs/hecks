# Helpers for specs of which engine a boot runs on: they answer `HECKS_ENGINE` for one example.
module EngineChoice
  # Answers `value` for `HECKS_ENGINE` in this example and leaves every other variable alone.
  #
  # @param value [String, nil] what the variable holds
  # @return [void]
  def with_engine(value)
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("HECKS_ENGINE").and_return(value)
  end

  # @return [Symbol] the engine a boot left at its default would run on
  def default_engine = Hecks::Assembly.selected_engine(Hecks::Assembly::FROM_ENV)
end
