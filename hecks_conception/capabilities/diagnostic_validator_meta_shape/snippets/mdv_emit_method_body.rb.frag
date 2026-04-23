        a = method["attrs"]
        indent = "      " # 6 spaces: module → module → class
        prefix = a["receiver"] == "self" ? "def self." : "def "
        sig = a["signature"].empty? ? "#{prefix}#{a["name"]}" : "#{prefix}#{a["name"]}(#{a["signature"]})"
        body = File.read(REPO_ROOT.join(a["body_snippet"]))
        doc = emit_method_doc(a)
        "#{doc}#{indent}#{sig}\n#{body}#{indent}end\n"
