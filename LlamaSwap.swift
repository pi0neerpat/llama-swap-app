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
    private var configWindow: NSWindow!
    private var configTextView: NSTextView!
    private var configPath: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".llama-swap/config.yaml")
    }

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

        let mainMenu = NSMenu()
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")

        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)
        NSApp.mainMenu = mainMenu

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
        let editConfigItem = NSMenuItem(title: "Edit Models & Config", action: #selector(openConfigEditor), keyEquivalent: ",")
        editConfigItem.target = self
        settingsMenu.addItem(editConfigItem)
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

    @objc private func openConfigEditor() {
        if configWindow == nil {
            prepareConfigEditor()
        }

        loadConfig()
        NSApp.setActivationPolicy(.regular)
        configWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func prepareConfigEditor() {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 760, height: 520))
        textView.isEditable = true
        textView.isSelectable = true
        textView.drawsBackground = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 760, height: CGFloat.greatestFiniteMagnitude)
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        configTextView = textView

        let scrollView = NSScrollView(frame: .zero)
        scrollView.hasVerticalScroller = true
        scrollView.documentView = textView
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let pathLabel = NSTextField(labelWithString: configPath.path)
        pathLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.lineBreakMode = .byTruncatingMiddle

        let revealButton = NSButton(title: "Reveal in Finder", target: self, action: #selector(revealConfig))
        revealButton.bezelStyle = .rounded

        let revertButton = NSButton(title: "Revert", target: self, action: #selector(revertConfig))
        revertButton.bezelStyle = .rounded

        let saveButton = NSButton(title: "Save", target: self, action: #selector(saveConfig))
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"

        let pathRow = NSStackView(views: [pathLabel, revealButton])
        pathRow.orientation = .horizontal
        pathRow.alignment = .centerY
        pathRow.distribution = .fill

        let buttonRow = NSStackView(views: [revertButton, saveButton])
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 8

        let content = NSStackView(views: [pathRow, scrollView, buttonRow])
        content.orientation = .vertical
        content.alignment = .leading
        content.distribution = .fill
        content.spacing = 10
        content.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        content.translatesAutoresizingMaskIntoConstraints = false

        let rootView = NSView()
        rootView.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: rootView.topAnchor),
            content.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
            pathRow.widthAnchor.constraint(equalTo: content.widthAnchor),
            pathLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 560),
            scrollView.widthAnchor.constraint(equalTo: content.widthAnchor),
            scrollView.heightAnchor.constraint(equalToConstant: 520),
            buttonRow.trailingAnchor.constraint(equalTo: content.trailingAnchor)
        ])

        configWindow = NSWindow(
            contentRect: NSMakeRect(0, 0, 760, 580),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        configWindow.title = "Models & llama-swap Config"
        configWindow.contentView = rootView
        configWindow.minSize = NSSize(width: 600, height: 400)
        configWindow.center()
    }

    private func loadConfig() {
        do {
            configTextView.string = try String(contentsOf: configPath, encoding: .utf8)
        } catch {
            if (error as NSError).code == NSFileReadNoSuchFileError {
                configTextView.string = """
models:
  # example-model:
  #   cmd: >-
  #     "/opt/homebrew/bin/llama-server" --host 0.0.0.0 --port ${PORT} --model "/absolute/path/to/model.gguf"
"""
            } else {
                showConfigAlert(
                    title: "Could Not Read Config",
                    message: error.localizedDescription
                )
            }
        }
    }

    @objc private func revertConfig() {
        loadConfig()
        configWindow.title = "Models & llama-swap Config"
    }

    @objc private func saveConfig() {
        do {
            try FileManager.default.createDirectory(
                at: configPath.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try configTextView.string.write(to: configPath, atomically: true, encoding: .utf8)
            configWindow.title = "Models & llama-swap Config - Saved"
            appendServerLog("Saved llama-swap config: \(configPath.path)\n")
            appendServerLog("llama-swap will reload the config when --watch-config detects the change.\n")
        } catch {
            showConfigAlert(
                title: "Could Not Save Config",
                message: error.localizedDescription
            )
        }
    }

    @objc private func revealConfig() {
        NSWorkspace.shared.selectFile(
            configPath.path,
            inFileViewerRootedAtPath: configPath.deletingLastPathComponent().path
        )
    }

    private func showConfigAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
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
        let startupID = startupAttemptID
        startupDeadline = Date().addingTimeInterval(10)
        webView.isHidden = true
        serverLog = ""
        updateLog()
        setStatus("Starting llama-swap…", detail: "Launching the local server.", isError: false)

        var request = URLRequest(url: URL(string: "http://localhost:8080")!)
        request.timeoutInterval = 1
        URLSession.shared.dataTask(with: request) { [weak self] _, response, _ in
            DispatchQueue.main.async {
                guard let self, startupID == self.startupAttemptID else { return }
                if let response = response as? HTTPURLResponse, response.statusCode > 0 {
                    self.serverProcess = nil
                    self.setStatus("llama-swap is ready", detail: "Loading the web UI at http://localhost:8080", isError: false)
                    self.webView.isHidden = false
                    self.webView.load(URLRequest(url: URL(string: "http://localhost:8080")!))
                    self.preloadRecentModel()
                    return
                }
                self.launchServerProcess(startupID: startupID)
            }
        }.resume()
    }

    private func launchServerProcess(startupID: UUID) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/llama-swap")
        task.arguments = [
            "--config", configPath.path,
            "--listen", "localhost:8080",
            "--watch-config"
        ]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        serverOutputPipes = [stdoutPipe, stderrPipe]
        task.standardOutput = stdoutPipe
        task.standardError = stderrPipe
        stdoutDrained = false
        stderrDrained = false
        serverExitStatus = nil
        configureOutputPipe(stdoutPipe, stream: "stdout", generation: startupID)
        configureOutputPipe(stderrPipe, stream: "stderr", generation: startupID)

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
            pollServer(attempt: 1, startupID: startupID)
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
