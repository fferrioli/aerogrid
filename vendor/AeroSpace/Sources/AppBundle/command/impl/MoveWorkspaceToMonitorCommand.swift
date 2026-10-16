import AppKit
import Common

struct MoveWorkspaceToMonitorCommand: Command {
    let args: MoveWorkspaceToMonitorCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = true

    func run(_ env: CmdEnv, _ io: CmdIo) -> BinaryExitCode {
        guard let target = args.resolveTargetOrReportError(env, io) else { return .fail }
        let focusedWorkspace = target.workspace
        let prevMonitor = focusedWorkspace.workspaceMonitor

        switch args.target.val.resolve(target.workspace.workspaceMonitor, wrapAround: args.wrapAround) {
            case .success(let targetMonitor):
                if targetMonitor.monitorId_oneBased == prevMonitor.monitorId_oneBased {
                    return .succ
                }
                if placeWorkspaceOnMonitor(focusedWorkspace, targetMonitor: targetMonitor) {
                    return .succ
                } else {
                    return .fail(io.err(
                        "Can't move workspace '\(focusedWorkspace.name)' to monitor '\(targetMonitor.name)'. workspace-to-monitor-force-assignment doesn't allow it",
                    ))
                }
            case .failure(let msg):
                return .fail(io.err(msg))
        }
    }
}

@MainActor
func placeWorkspaceOnMonitor(_ workspace: Workspace, targetMonitor: MonitorInfo) -> Bool {
    let previousMonitor = workspace.workspaceMonitor
    let wasVisible = workspace.isVisible
    guard targetMonitor.setActiveWorkspace(workspace) else { return false }
    // An invisible cell has an assigned monitor but has not vacated its visible workspace.
    // Fill the source display only when the workspace actually occupied it.
    if wasVisible && previousMonitor.rect.topLeftCorner != targetMonitor.rect.topLeftCorner {
        let stubWorkspace = getStubWorkspace(for: previousMonitor)
        check(
            previousMonitor.setActiveWorkspace(stubWorkspace),
            "getStubWorkspace generated incompatible stub workspace (\(stubWorkspace)) for the monitor (\(previousMonitor)",
        )
    }
    return true
}
