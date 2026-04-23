        a = helper["attrs"]
        body = File.read(REPO_ROOT.join(a["body_snippet"]))
        doc = a["doc_comment"].to_s
        # doc_comment is the PREAMBLE — may hold /// doc, // comments,
        # and/or #[attribute] lines. Emit verbatim if present.
        doc_block = doc.empty? ? "" : doc + "\n"
        core = if body.strip.empty?
                 # Empty-body stubs (e.g. #[allow(dead_code)] placeholders)
                 # emit inline: `fn x() {}` on one line.
                 "#{doc_block}#{a["signature"]} {}\n"
               else
                 "#{doc_block}#{a["signature"]} {\n#{body}}\n"
               end
        trailing_blank ? core + "\n" : core
