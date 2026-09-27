# Build-time generator: turns one domain's canonical IR into Rust source under rust/src/generated/.
# The compiled binary never parses or interprets bluebooks.
#
#   bin/project_rust <domain>
#
# The IR arrives JSON-shaped, so mutation ops, targets and attribute names are Strings; compare
# them with `.to_s`. Commands the kernel cannot express are skipped loudly, by name and reason.
module RustProjection
end

require_relative "project/write_if_changed"
require_relative "project/skip_reason"
require_relative "project/exemplar"
require_relative "project/expr_emitter"
require_relative "project/naming"
require_relative "project/reference_specs"
require_relative "project/constraints"
require_relative "project/fielded"
require_relative "project/json_codec"
require_relative "project/types"
require_relative "project/bridging"
require_relative "project/mutations"
require_relative "project/dependency_planning"
require_relative "project/commands"
require_relative "project/ports"
require_relative "project/registry"
require_relative "project/reactions"
require_relative "project/queries"
require_relative "project/read_models"
require_relative "project/domain_generator"
