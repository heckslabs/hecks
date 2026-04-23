        raise "hecks-life not built: #{HECKS_LIFE}" unless HECKS_LIFE.exist?
        out, err, status = Open3.capture3(HECKS_LIFE.to_s, "dump-fixtures", shape_path.to_s)
        raise "dump-fixtures failed: #{err}" unless status.success?
        JSON.parse(out)["fixtures"]
