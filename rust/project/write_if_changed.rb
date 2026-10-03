require "hecks/rust_build/write_if_changed"

module RustProjection
  # The write-if-unchanged helper moved to `Hecks::RustBuild::WriteIfChanged`, which the
  # codegen-backed `hecks project_rust` also uses; this name stays until this generator is deleted.
  WriteIfChanged = Hecks::RustBuild::WriteIfChanged
end
