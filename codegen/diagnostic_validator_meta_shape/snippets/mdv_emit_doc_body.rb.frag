        # Doc snippet ends with `\n`; add one more for blank-line separator
        # before the module nesting begins.
        File.read(REPO_ROOT.join(klass["attrs"]["doc_snippet"])) + "\n"
