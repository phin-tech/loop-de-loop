import AppKit
import Foundation
import LoopCore

let usage = """
loopctl — control LoopDeLoop (the Loupedeck Live manager)

  loopctl status                         device, profile, page
  loopctl pages | profiles               list pages / profiles
  loopctl page <next|prev|N|name>        switch page (N is 1-based)
  loopctl profile <name>                 switch profile
  loopctl set-key <0-11> [options]       change a key until cleared (or --persist)
      --title T  --bg RRGGBB  --title-color RRGGBB  --font-size N
      --symbol sf.symbol.name  --symbol-color RRGGBB  --image PATH
      --page P   --persist
  loopctl clear-key <N|all> [--page P]   remove runtime changes
  loopctl label <tl|cl|bl|tr|cr|br> <text>   knob label on the side strip
  loopctl button-color <0-7> <RRGGBB>
  loopctl brightness <0-100|+10|-10>
  loopctl vibrate [pattern]
  loopctl press <key:N|button:N|knob:tl>  simulate a press
  loopctl turn <knob> <delta>            simulate a knob turn
  loopctl export <file> [--profile NAME | --all]   current profile, a named one, or a full backup
  loopctl import <file>                  add the file's profiles alongside yours
  loopctl restore <file>                 replace everything (your setup is backed up first)
  loopctl backup                         full backup to Application Support/LoopDeLoop/Backups
  loopctl save                           write the current config to config.json
  loopctl reload                         re-read config.json
  loopctl serve                          run the engine without the app (debugging)

The same commands work as URLs: open -g 'loopdeloop://set-key/3?title=Hi&bg=ff0000'
"""

var arguments = Array(CommandLine.arguments.dropFirst())
if arguments.isEmpty || ["-h", "--help", "help"].contains(arguments[0]) {
    print(usage)
    exit(arguments.isEmpty ? 2 : 0)
}

if arguments[0] == "serve" {
    // Headless engine: same behaviour as the app minus the UI.
    _ = NSApplication.shared
    let engine = Engine()
    engine.start()
    FileHandle.standardError.write(Data("loopctl serve: listening on \(Paths.controlSocket.path)\n".utf8))
    withExtendedLifetime(engine) { RunLoop.main.run() }
    exit(0)
}

guard var request = ControlRequest(arguments: arguments) else {
    print(usage)
    exit(2)
}
// The app runs in another directory, so send file paths absolute.
if ["export", "import", "restore"].contains(request.command), let path = request.positional(0) {
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    request.args["0"] = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, relativeTo: cwd).standardizedFileURL.path
}
do {
    let response = try ControlClient.send(request)
    let out = response.ok ? FileHandle.standardOutput : FileHandle.standardError
    if !(response.ok && response.message == "ok") { out.write(Data((response.message + "\n").utf8)) }
    exit(response.ok ? 0 : 1)
} catch {
    FileHandle.standardError.write(Data("loopctl: \(error)\n".utf8))
    exit(1)
}
