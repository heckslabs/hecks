        path = attrs["doc_snippet"].to_s
        return "" if path.empty?
        File.read(REPO_ROOT.join(path))
