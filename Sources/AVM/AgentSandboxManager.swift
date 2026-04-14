import Foundation
import Combine
import CoreGraphics

/// Manages multiple agent sandboxes (virtual displays) for input isolation.
/// Each sandbox provides a dedicated virtual monitor that agents can control
/// without interfering with the user's physical display.
@MainActor
final class AgentSandboxManager: ObservableObject {

    static let shared = AgentSandboxManager()

    /// All active sandboxes, keyed by their ID.
    @Published private(set) var sandboxes: [UUID: AgentSandbox] = [:]

    /// Sandbox-to-workspace mapping (which workspace is viewing which sandbox).
    @Published private(set) var workspaceSandboxes: [UUID: UUID] = [:] // workspaceId -> sandboxId

    private init() {}

    // MARK: - Create / Destroy

    /// Create a new sandbox with a virtual display.
    /// Returns nil if the virtual display couldn't be created.
    func createSandbox(
        name: String,
        resolution: CGSize = CGSize(width: 1920, height: 1080)
    ) -> AgentSandbox? {
        let sandbox = AgentSandbox(name: name, resolution: resolution)

        guard sandbox.createDisplay() != nil else {
            return nil
        }

        sandboxes[sandbox.id] = sandbox

        // Register with AVM if daemon is running
        Task {
            if let displayID = sandbox.displayID {
                _ = await AVMStatusMonitor.shared.registerAgent(
                    name: "sandbox-\(name)",
                    pid: UInt32(ProcessInfo.processInfo.processIdentifier),
                    workspaceId: sandbox.id
                )
                _ = displayID // suppress unused warning
            }
        }

        return sandbox
    }

    /// Destroy a sandbox and its virtual display.
    func destroySandbox(id: UUID) {
        guard let sandbox = sandboxes[id] else { return }
        sandbox.destroyDisplay()
        sandboxes.removeValue(forKey: id)

        // Remove workspace mapping
        workspaceSandboxes = workspaceSandboxes.filter { $0.value != id }
    }

    /// Destroy all sandboxes.
    func destroyAll() {
        for (_, sandbox) in sandboxes {
            sandbox.destroyDisplay()
        }
        sandboxes.removeAll()
        workspaceSandboxes.removeAll()
    }

    // MARK: - Workspace Mapping

    /// Associate a workspace with a sandbox (for tracking which workspace views which sandbox).
    func associateWorkspace(_ workspaceId: UUID, withSandbox sandboxId: UUID) {
        workspaceSandboxes[workspaceId] = sandboxId
    }

    /// Get the sandbox associated with a workspace.
    func sandbox(forWorkspace workspaceId: UUID) -> AgentSandbox? {
        guard let sandboxId = workspaceSandboxes[workspaceId] else { return nil }
        return sandboxes[sandboxId]
    }

    // MARK: - Queries

    /// All active sandbox display IDs.
    var activeDisplayIDs: [CGDirectDisplayID] {
        sandboxes.values.compactMap { $0.displayID }
    }

    /// Summary info for socket API responses.
    var statusInfo: [[String: Any]] {
        sandboxes.values.map { sandbox in
            var info: [String: Any] = [
                "id": sandbox.id.uuidString,
                "name": sandbox.name,
                "active": sandbox.isActive,
                "resolution": "\(Int(sandbox.resolution.width))x\(Int(sandbox.resolution.height))",
            ]
            if let displayID = sandbox.displayID {
                info["display_id"] = Int(displayID)
            }
            if let error = sandbox.errorMessage {
                info["error"] = error
            }
            return info
        }
    }
}
