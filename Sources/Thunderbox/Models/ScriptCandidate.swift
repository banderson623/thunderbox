import Foundation

/// A runnable thing discovered while scanning a folder, shown in the Add sheet.
struct ScriptCandidate: Identifiable, Hashable {
    let id = UUID()
    var name: String            // e.g. "dev" or "run.sh"
    var folder: String          // working directory to run in
    var command: String         // the command Thunderbox will execute
    var kind: ServiceKind
    var isServer: Bool          // heuristic: does this start a web server?
    var serverScore: Int        // higher = more confident it's a server
    var declaredPort: Int?      // port parsed from the command, if any
    var detail: String          // the underlying raw command, for display

    func makeService() -> Service {
        // The service's top-level name is the project/folder name; the specific script it
        // runs is shown as the command subtitle. (The Add sheet still labels candidates by
        // script via `name`, so you choose by script but manage by project.)
        Service(name: (folder as NSString).lastPathComponent, folder: folder,
                command: command, kind: kind, isServer: isServer, declaredPort: declaredPort)
    }
}
