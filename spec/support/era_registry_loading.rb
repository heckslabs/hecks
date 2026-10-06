require "tempfile"

# Loads bluebook source text into a fresh registry the way a boot does, for the PostgresEra
# lineage specs: library first, then the bluebook, then any data translation that rides with it.
module EraRegistryLoading
  # @param source [String] the bluebook source
  # @param translation_source [String, nil] a `Hecks.data_translation` source evaluated after it
  # @return [Hecks::Runtime::Registry] the registry holding what the sources declared
  def load_registry(source, translation_source: nil)
    registry = Hecks::Runtime::Registry.new
    loading = Hecks::Ports::Loading.bootstrap
    with_source_file(source) do |path|
      Hecks.with_registry(registry) { evaluate_sources(loading, source, path, translation_source) }
    end
    registry
  end

  private

  # Yields the path of a temporary `.bluebook` holding `source`, so blocks in it have a file
  # to be read back from.
  def with_source_file(source)
    file = Tempfile.new(["era-", ".bluebook"])
    file.write(source)
    file.flush
    yield file.path
  ensure
    file&.close!
  end

  def evaluate_sources(loading, source, path, translation_source)
    loading.load_library
    Kernel.eval(source, TOPLEVEL_BINDING, path, 1)
    eval(translation_source) if translation_source
  end
end
