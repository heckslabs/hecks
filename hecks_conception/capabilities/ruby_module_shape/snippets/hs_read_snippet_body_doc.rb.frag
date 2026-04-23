      # Read a .rs.frag snippet file, stripping the leading //-comment
      # header. Everything from the first non-comment, non-empty line
      # onward is returned verbatim (specializers interpolate as fn body).
