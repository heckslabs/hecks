/// One scheduled dispatch within a cadence. `command_name` is the
/// qualified `Aggregate.Command` ; `attrs` carries literal kwargs as
/// ordered (key, source-text-value) pairs so the canonical JSON shape
/// is unambiguous and round-trips byte-identically with the Ruby dumper.
