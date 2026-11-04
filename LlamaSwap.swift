import Cocoa
import ServiceManagement
import WebKit

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate, WKNavigationDelegate, WKScriptMessageHandler {
    var window: NSWindow!
    var webView: WKWebView!
    var serverProcess: Process?

    private var statusItem: NSStatusItem!
    private var startAtLoginItem: NSMenuItem!
    private var serverOutputPipes: [Pipe] = []
    private var serverLog = ""
    private var startupAttemptID = UUID()
    private var startupDeadline = Date.distantFuture
    private var stdoutDrained = true
    private var stderrDrained = true
    private var serverExitStatus: Int32?
    private let recentModelDefaultsKey = "recentlyReadyModel"
    private var statusLabel: NSTextField!
    private var detailLabel: NSTextField!
    private var outputLabel: NSTextField!
    private var logTextView: NSTextView!
    private var logScrollView: NSScrollView!
    private var retryButton: NSButton!
    private var detailsButton: NSButton!
    private var detailsExpanded = true

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        NSApp.setActivationPolicy(.accessory)
        prepareWindow()
        startServer()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "cpu", accessibilityDescription: "Llama Swap")
            button.image?.isTemplate = true
        }

        let menu = NSMenu()
        menu.delegate = self
        let openItem = NSMenuItem(title: "Open Llama Swap", action: #selector(openWindow), keyEquivalent: "o")
        openItem.target = self
        menu.addItem(openItem)

        let settingsItem = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        let settingsMenu = NSMenu()
        startAtLoginItem = NSMenuItem(title: "Start at Login", action: #selector(toggleStartAtLogin), keyEquivalent: "")
        startAtLoginItem.target = self
        settingsMenu.addItem(startAtLoginItem)
        settingsItem.submenu = settingsMenu
        menu.addItem(settingsItem)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit Llama Swap", action: #selector(NSApp.terminate(_:)), keyEquivalent: "q")
        quitItem.target = NSApp
        menu.addItem(quitItem)
        statusItem.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        startAtLoginItem.state = loginItemIsEnabled ? .on : .off
    }

    @objc private func toggleStartAtLogin() {
        do {
            if loginItemIsEnabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
            startAtLoginItem.state = loginItemIsEnabled ? .on : .off
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not update Start at Login"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            startAtLoginItem.state = loginItemIsEnabled ? .on : .off
        }
    }

    private var loginItemIsEnabled: Bool {
        let status = SMAppService.mainApp.status
        return status == .enabled || status == .requiresApproval
    }

    @objc private func openWindow() {
        NSApp.setActivationPolicy(.regular)
        if window == nil {
            prepareWindow()
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func prepareWindow() {
        let contentController = WKUserContentController()
        contentController.add(self, name: "recentModel")
        contentController.addUserScript(WKUserScript(
            source: """
            (() => {
              const NativeEventSource = window.EventSource;
              if (!NativeEventSource) return;
              const TrackedEventSource = function (...args) {
                const source = new NativeEventSource(...args);
                source.addEventListener("message", event => {
                  let envelope;
                  try {
                    envelope = JSON.parse(event.data);
                    if (envelope.type !== "modelStatus" || typeof envelope.data !== "string") return;
                    const models = JSON.parse(envelope.data);
                    const ready = models.filter(model =>
                      model.state === "ready" &&
                      typeof model.id === "string" &&
                      model.id.length > 0 &&
                      !model.peerID &&
                      model.playgroundType !== "profile" &&
                      model.playgroundType !== "selector"
                    );
                    if (!ready.length) return;
                    ready.sort((a, b) => (a.uptimeMs ?? Number.MAX_SAFE_INTEGER) - (b.uptimeMs ?? Number.MAX_SAFE_INTEGER));
                    window.webkit.messageHandlers.recentModel.postMessage(ready[0].id);
                  } catch (error) {
                    console.error("Could not track the most recently ready model:", error);
                  }
                });
                return source;
              };
              TrackedEventSource.prototype = NativeEventSource.prototype;
              Object.setPrototypeOf(TrackedEventSource, NativeEventSource);
              window.EventSource = TrackedEventSource;
            })();
            """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))

        let config = WKWebViewConfiguration()
        config.userContentController = contentController
        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.isHidden = true

        statusLabel = NSTextField(labelWithString: "Starting llama-swap…")
        statusLabel.font = .boldSystemFont(ofSize: 15)

        detailLabel = NSTextField(wrappingLabelWithString: "Launching the local server.")
        detailLabel.maximumNumberOfLines = 2

        outputLabel = NSTextField(labelWithString: "llama-swap output")
        outputLabel.font = .systemFont(ofSize: 11, weight: .semibold)

        retryButton = NSButton(title: "Retry", target: self, action: #selector(retryStartup))
        retryButton.bezelStyle = .rounded
        retryButton.isHidden = true

        logTextView = NSTextView(frame: NSRect(x: 0, y: 0, width: 900, height: 110))
        logTextView.isEditable = false
        logTextView.isSelectable = true
        logTextView.drawsBackground = false
        logTextView.isVerticallyResizable = true
        logTextView.isHorizontallyResizable = false
        logTextView.autoresizingMask = [.width]
        logTextView.textContainer?.widthTracksTextView = true
        logTextView.textContainer?.containerSize = NSSize(width: 900, height: CGFloat.greatestFiniteMagnitude)
        logTextView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)

        logScrollView = NSScrollView(frame: .zero)
        logScrollView.hasVerticalScroller = true
        logScrollView.documentView = logTextView
        logScrollView.heightAnchor.constraint(equalToConstant: 110).isActive = true

        detailsButton = NSButton(title: "Hide Details", target: self, action: #selector(toggleDetails))
        detailsButton.bezelStyle = .rounded

        let header = NSStackView(views: [statusLabel, retryButton, detailsButton])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.distribution = .fill
        header.spacing = 12

        let statusContent = NSStackView(views: [header, detailLabel, outputLabel, logScrollView])
        statusContent.orientation = .vertical
        statusContent.alignment = .leading
        statusContent.distribution = .fill
        statusContent.spacing = 8
        statusContent.translatesAutoresizingMaskIntoConstraints = false

        let statusPanel = NSView()
        statusPanel.wantsLayer = true
        statusPanel.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        statusPanel.addSubview(statusContent)

        let rootView = NSView()
        rootView.addSubview(statusPanel)
        rootView.addSubview(webView)
        statusPanel.translatesAutoresizingMaskIntoConstraints = false
        webView.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            statusPanel.topAnchor.constraint(equalTo: rootView.topAnchor),
            statusPanel.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            statusPanel.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),

            statusContent.topAnchor.constraint(equalTo: statusPanel.topAnchor, constant: 12),
            statusContent.leadingAnchor.constraint(equalTo: statusPanel.leadingAnchor, constant: 16),
            statusContent.trailingAnchor.constraint(equalTo: statusPanel.trailingAnchor, constant: -16),
            statusContent.bottomAnchor.constraint(equalTo: statusPanel.bottomAnchor, constant: -12),
            header.widthAnchor.constraint(equalTo: statusContent.widthAnchor),
            detailLabel.widthAnchor.constraint(equalTo: statusContent.widthAnchor),
            outputLabel.widthAnchor.constraint(equalTo: statusContent.widthAnchor),
            logScrollView.widthAnchor.constraint(equalTo: statusContent.widthAnchor),

            webView.topAnchor.constraint(equalTo: statusPanel.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor)
        ])

        window = NSWindow(
            contentRect: NSMakeRect(0, 0, 1000, 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.delegate = self
        window.title = "Llama Swap"
        window.contentView = rootView
        window.center()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)
        return false
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "recentModel",
              let modelID = message.body as? String,
              !modelID.isEmpty else { return }
        UserDefaults.standard.set(modelID, forKey: recentModelDefaultsKey)
    }

    func startServer() {
        startupAttemptID = UUID()
        startupDeadline = Date().addingTimeInterval(10)
        webView.isHidden = true
        serverLog = ""
        updateLog()
        setStatus("Starting llama-swap…", detail: "Launching the local server.", isError: false)

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/llama-swap")
        task.arguments = ["--config", NSHomeDirectory() + "/.llama-swap/config.yaml", "--listen", "localhost:8080"]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        serverOutputPipes = [stdoutPipe, stderrPipe]
        task.standardOutput = stdoutPipe
        task.standardError = stderrPipe
        stdoutDrained = false
        stderrDrained = false
        serverExitStatus = nil
        configureOutputPipe(stdoutPipe, stream: "stdout", generation: startupAttemptID)
        configureOutputPipe(stderrPipe, stream: "stderr", generation: startupAttemptID)

        task.terminationHandler = { [weak self] process in
            DispatchQueue.main.async {
                guard let self, self.serverProcess === process else { return }
                self.serverExitStatus = process.terminationStatus
                self.showExitIfOutputDrained()
            }
        }

        do {
            try task.run()
            serverProcess = task
            pollServer(attempt: 1, startupID: startupAttemptID)
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            stdoutDrained = true
            stderrDrained = true
            serverOutputPipes = []
            serverProcess = nil
            setStatus("Could not launch llama-swap", detail: error.localizedDescription, isError: true)
            retryButton.isHidden = false
        }
    }

    private func configureOutputPipe(_ outputPipe: Pipe, stream: String, generation: UUID) {
        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                DispatchQueue.main.async {
                    guard let self, self.startupAttemptID == generation else { return }
                    if stream == "stdout" {
                        self.stdoutDrained = true
                    } else {
                        self.stderrDrained = true
                    }
                    self.showExitIfOutputDrained()
                }
                return
            }
            let output = String(decoding: data, as: UTF8.self)
            DispatchQueue.main.async {
                guard let self, self.startupAttemptID == generation else { return }
                self.appendServerLog("[\(stream)] \(output)")
            }
        }
    }

    private func showExitIfOutputDrained() {
        guard let exitStatus = serverExitStatus, stdoutDrained, stderrDrained else { return }
        let detail = serverLog.isEmpty
            ? "The process exited with status \(exitStatus) without producing output."
            : "The process exited with status \(exitStatus). See the output below."
        setStatus("llama-swap stopped", detail: detail, isError: true)
        webView.isHidden = true
        retryButton.isHidden = false
    }

    private func pollServer(attempt: Int, startupID: UUID) {
        guard startupID == startupAttemptID else { return }
        guard let process = serverProcess, process.isRunning else {
            return
        }
        guard Date() < startupDeadline else {
            setStatus("llama-swap did not become ready", detail: "No response from localhost:8080 within 10 seconds. Check the output below, then retry.", isError: true)
            retryButton.isHidden = false
            return
        }

        guard let url = URL(string: "http://localhost:8080") else {
            setStatus("Invalid server address", detail: "Could not create the local server URL.", isError: true)
            retryButton.isHidden = false
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = min(1.0, startupDeadline.timeIntervalSinceNow)
        URLSession.shared.dataTask(with: request) { [weak self] _, response, _ in
            DispatchQueue.main.async {
                guard let self, startupID == self.startupAttemptID else { return }

                guard Date() < self.startupDeadline else {
                    self.setStatus("llama-swap did not become ready", detail: "No response from localhost:8080 within 10 seconds. Check the output below, then retry.", isError: true)
                    self.retryButton.isHidden = false
                    return
                }

                guard process.isRunning else {
                    self.setStatus("llama-swap exited during startup", detail: "Check the server output below.", isError: true)
                    self.retryButton.isHidden = false
                    return
                }

                if let response = response as? HTTPURLResponse, response.statusCode > 0 {
                    self.setStatus("llama-swap is ready", detail: "Loading the web UI at \(url.absoluteString)", isError: false)
                    self.webView.isHidden = false
                    self.webView.load(URLRequest(url: url))
                    self.preloadRecentModel()
                    return
                }

                self.setStatus("Waiting for llama-swap…", detail: "Checking localhost:8080 (attempt \(attempt)).", isError: false)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.pollServer(attempt: attempt + 1, startupID: startupID)
                }
            }
        }.resume()
    }

    private func preloadRecentModel() {
        guard let modelID = UserDefaults.standard.string(forKey: recentModelDefaultsKey),
              !modelID.isEmpty else {
            appendServerLog("No previously ready model is saved; llama-swap will load models on demand.\n")
            return
        }

        var components = URLComponents(string: "http://localhost:8080/props")
        components?.queryItems = [URLQueryItem(name: "model", value: modelID)]
        guard let url = components?.url else {
            setStatus("Could not restore the recent model", detail: "Could not construct a request for model \(modelID).", isError: true)
            return
        }

        setStatus("Restoring the recent model…", detail: "Loading \(modelID).", isError: false)
        appendServerLog("Restoring most recently ready model: \(modelID)\n")
        var request = URLRequest(url: url)
        request.timeoutInterval = 300
        URLSession.shared.dataTask(with: request) { [weak self] _, response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    self.appendServerLog("Could not restore \(modelID): \(error.localizedDescription)\n")
                    self.setStatus("Could not restore the recent model", detail: error.localizedDescription, isError: true)
                    return
                }

                guard let httpResponse = response as? HTTPURLResponse,
                      (200..<300).contains(httpResponse.statusCode) else {
                    let statusCode = (response as? HTTPURLResponse)?.statusCode
                    let detail = statusCode.map { "The model endpoint returned HTTP \($0)." } ?? "No HTTP response was received."
                    self.appendServerLog("Could not restore \(modelID): \(detail)\n")
                    self.setStatus("Could not restore the recent model", detail: detail, isError: true)
                    return
                }

                self.setStatus("Recent model loaded", detail: "\(modelID) is ready.", isError: false)
            }
        }.resume()
    }

    private func appendServerLog(_ output: String) {
        serverLog += output
        if serverLog.count > 8000 {
            serverLog = String(serverLog.suffix(8000))
        }
        updateLog()
    }

    private func updateLog() {
        logTextView?.string = serverLog.isEmpty ? "Server output will appear here." : serverLog
        logTextView?.scrollToEndOfDocument(nil)
    }

    private func setStatus(_ title: String, detail: String, isError: Bool) {
        statusLabel.stringValue = title
        statusLabel.textColor = isError ? .systemRed : .labelColor
        detailLabel.stringValue = detail
        retryButton.isHidden = !isError
        if isError {
            setDetailsExpanded(true)
        }
    }

    @objc private func toggleDetails() {
        setDetailsExpanded(!detailsExpanded)
    }

    private func setDetailsExpanded(_ expanded: Bool) {
        detailsExpanded = expanded
        detailLabel.isHidden = !expanded
        outputLabel.isHidden = !expanded
        logScrollView.isHidden = !expanded
        detailsButton.title = expanded ? "Hide Details" : "Show Details"
    }

    @objc private func retryStartup() {
        if serverProcess?.isRunning == true {
            startupAttemptID = UUID()
            startupDeadline = Date().addingTimeInterval(10)
            webView.isHidden = true
            setStatus("Checking llama-swap…", detail: "Waiting for localhost:8080.", isError: false)
            pollServer(attempt: 1, startupID: startupAttemptID)
        } else {
            startServer()
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        setStatus("Loading web UI…", detail: "The server is responding; waiting for the page to load.", isError: false)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        setStatus("Web UI loaded", detail: "Connected to llama-swap at localhost:8080.", isError: false)
        setDetailsExpanded(false)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        showWebViewError(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        showWebViewError(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        setStatus("Web UI process stopped", detail: "Retry to reload the page.", isError: true)
        self.webView.isHidden = true
    }

    private func showWebViewError(_ error: Error) {
        webView.isHidden = true
        setStatus("Could not load the web UI", detail: "\(error.localizedDescription) Retry to try again.", isError: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let process = serverProcess, process.isRunning {
            process.terminate()

            let deadline = Date().addingTimeInterval(2.0)
            while process.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.1)
            }

            if process.isRunning {
                process.interrupt()
            }
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.activate(ignoringOtherApps: true)
app.run()
