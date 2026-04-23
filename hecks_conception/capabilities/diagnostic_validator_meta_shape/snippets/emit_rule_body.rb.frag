        a = validator["attrs"]
        body = File.read(REPO_ROOT.join(a["check_body_snippet"]))
        prefix = leading_blank ? "\n" : ""
        suffix = trailing_blank ? "\n" : ""
        "#{prefix}#{a["rule_signature"]} {\n#{body}}\n#{suffix}"
