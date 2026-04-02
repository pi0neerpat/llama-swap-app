import Cocoa
import WebKit

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var webView: WKWebView!
    var serverProcess: Process?

    func applicationDidFinishLaunching(_ notification: Notification) {
        startServer()
        pollAndOpenWindow()
    }

    func startServer() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/llama-swap")
        task.arguments = ["--config", NSHomeDirectory() + "/.llama-swap/config.yaml", "--listen", "localhost:8080"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            serverProcess = task
        } catch {
            let alert = NSAlert()
            alert.messageText = "Failed to start llama-swap"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            NSApp.terminate(nil)
        }
    }

    func pollAndOpenWindow() {
        DispatchQueue.global().async { [weak self] in
            let maxAttempts = 20
            for _ in 0..<maxAttempts {
                if self?.checkServer() == true {
                    DispatchQueue.main.async {
                        self?.openWindow()
                    }
                    return
                }
                Thread.sleep(forTimeInterval: 0.5)
            }
            DispatchQueue.main.async {
                // Open window anyway after timeout
                self?.openWindow()
            }
        }
    }

    func checkServer() -> Bool {
        guard let url = URL(string: "http://localhost:8080") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1.0
        let semaphore = DispatchSemaphore(value: 0)
        var success = false
        let task = URLSession.shared.dataTask(with: request) { _, response, _ in
            if let http = response as? HTTPURLResponse, http.statusCode > 0 {
                success = true
            }
            semaphore.signal()
        }
        task.resume()
        semaphore.wait()
        return success
    }

    func openWindow() {
        let config = WKWebViewConfiguration()
        webView = WKWebView(frame: .zero, configuration: config)

        window = NSWindow(
            contentRect: NSMakeRect(0, 0, 1000, 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Llama Swap"
        window.contentView = webView
        window.center()
        window.makeKeyAndOrderFront(nil)

        if let url = URL(string: "http://localhost:8080") {
            webView.load(URLRequest(url: url))
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let process = serverProcess, process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.activate(ignoringOtherApps: true)
app.run()
