# Contextual Help Icons

Every module card and command in the hecks-life web UI includes a small **?** button
that opens a context-aware help popup.

## How it works

The help system reads `data-domain-aggregate` and `data-domain-command` attributes
already present on the HTML elements. No pre-built documentation is needed.

For **modules**, the popup shows:
- The aggregate name (humanized)
- The description from the Bluebook definition
- Number of available commands
- Number of current records

For **commands**, the popup shows:
- The command name (humanized)
- The description from the Bluebook definition
- Required fields with their types

## Example

1. Start the server:
   ```
   hecks-life serve path/to/hecks/ 3100
   ```

2. Open any domain page in the browser

3. Hover over a module card header or command — the **?** icon appears

4. Click **?** to open the help popup

5. Click outside the popup or press the close button to dismiss
