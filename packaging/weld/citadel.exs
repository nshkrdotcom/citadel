unless Code.ensure_loaded?(Citadel.Workspace) do
  Code.require_file("../../lib/citadel/workspace.ex", __DIR__)
end

Citadel.Workspace.weld_manifest()
