// Temps Engine : lance l'enregistreur et le serveur Python, et les relance s'ils s'arrêtent.
// Cette app n'est recompilée que si son code change : c'est elle qui porte l'accès complet
// au disque, l'Accessibilité et l'Automatisation, que macOS lie à la signature de l'app.
import AppKit

let dossier = Bundle.main.bundleURL.deletingLastPathComponent()
/// Python 3.11 ou plus récent (tomllib) : Homebrew, python.org, puis celui du système.
let python = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
    .first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/usr/bin/python3"
let scripts = ["recorder.py", "server.py"]
var enfants: [String: Process] = [:]

func lancer(_ script: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: python)
    var env = ProcessInfo.processInfo.environment
    env["TEMPS_LANGUE"] = Locale.preferredLanguages.first.map { String($0.prefix(2)) } ?? "en"
    p.environment = env
    p.arguments = [dossier.appendingPathComponent(script).path]
    p.currentDirectoryURL = dossier
    let journal = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Temps/journal.log")
    try? FileManager.default.createDirectory(at: journal.deletingLastPathComponent(), withIntermediateDirectories: true)
    if !FileManager.default.fileExists(atPath: journal.path) { FileManager.default.createFile(atPath: journal.path, contents: nil) }
    if let h = try? FileHandle(forWritingTo: journal) { h.seekToEndOfFile(); p.standardOutput = h; p.standardError = h }
    try? p.run()
    enfants[script] = p
}

for s in scripts { lancer(s) }

// Relance toutes les 15 s ce qui s'est arrêté.
Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in
    for s in scripts where enfants[s]?.isRunning != true { lancer(s) }
}

// À l'arrêt de l'app, on arrête ses scripts.
NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in
    enfants.values.forEach { $0.terminate() }
}
signal(SIGTERM) { _ in enfants.values.forEach { $0.terminate() }; exit(0) }

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
app.run()
