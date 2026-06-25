        raise "storehouse not built: #{STOREHOUSE}" unless STOREHOUSE.exist?
        out, err, status = Open3.capture3(STOREHOUSE.to_s, "dump-fixtures", shape_path.to_s)
        raise "dump-fixtures failed: #{err}" unless status.success?
        JSON.parse(out)["fixtures"]
