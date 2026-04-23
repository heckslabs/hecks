        klass = pick_class
        methods = by_aggregate("RubyMethod")
                    .select { |m| m["attrs"]["class_name"] == klass["attrs"]["name"] }
                    .sort_by { |m| m["attrs"]["order"].to_i }
        public_methods = methods.select { |m| m["attrs"]["visibility"] == "public" }
        private_methods = methods.select { |m| m["attrs"]["visibility"] == "private" }

        [
          emit_doc(klass),
          emit_requires(klass),
          emit_module_open(klass),
          emit_class_header(klass),
          emit_constants(klass),
          emit_methods(public_methods, blank_before_first: true),
          emit_private_section(private_methods),
          emit_module_close(klass),
        ].join
