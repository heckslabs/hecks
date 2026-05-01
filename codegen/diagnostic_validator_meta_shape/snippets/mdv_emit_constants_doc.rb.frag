      # Emit RubyConstant rows matching this class, sorted by order.
      # Each constant line is indented one step deeper than the class,
      # preceded by a blank line ONLY when a preceding include block
      # exists (to separate the two). Classes with no includes get the
      # first constant butted directly against the class line.
      # Empty if no constants — whole block collapses.
