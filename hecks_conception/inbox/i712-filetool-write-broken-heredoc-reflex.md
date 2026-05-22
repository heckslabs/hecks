# i712 — FileTool.Write is broken → forces the heredoc reflex

`Tools::FileTool.Write` returns `ok:true` but never persists the file (documented:
`reference_filetool_write_broken.md`). So every file-write through the bus falls
back to `Tools::ShellTool.Bash` with a `cat > path <<'EOF' … EOF` heredoc. That's
NOT a wall-cheat — ShellTool is itself a storehouse adapter, so the heredoc goes
through the bus like everything else — but it IS a workaround that has become a
reflex, and a write that returns ok while writing nothing is a lying adapter.

Deeper: writing a file is a side-effect that should flow through a clean **File
primitive**, not a raw shell heredoc.

## Fix (prefer #2)
1. **Repair `FileTool.Write`** so it actually persists. VERIFY the current
   behaviour first — don't trust the memory note; it may already be fixed.
2. **Stand up a `File.Write` / `File.Read` primitive** in the primitive stdlib
   (`framework/primitive/primitive.bluebook`), same shape as `Primitive::Process.Spawn`
   (commit 1fa95018), bound to the real file-IO syscall. Then the FileTool file-adapter
   family collapses onto the primitive — part of the adapters-as-bluebook arc.

Either way: retire the heredoc reflex so file-writes are structured and honest
(an ok result means the bytes actually landed).
