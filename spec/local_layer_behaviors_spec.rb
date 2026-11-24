require "hecks/behaviors/rspec"

# The LocalLayer domain's own behaviours, run through the shim a consumer's suite would use.
Hecks::Behaviors::RSpec.describe_file(File.join(InMemoryDomain::ROOT, "lib", "hecks", "local_layer", "local_layer.behaviors"))
