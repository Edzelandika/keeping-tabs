import Foundation

struct BridgeRequest: Codable {
    var action: String
    var windowID: Int? = nil
    var index: Int? = nil
    var expectedURL: String? = nil
}
struct BridgeTiming: Codable {
    var queueMS: Double
    var helperMS: Double
    var callbackMS: Double
}
struct SwitchStages: Codable {
    var validationMS: Double = 0
    var selectionMS: Double = 0
    var verificationMS: Double = 0
}
struct BridgeReply: Codable {
    var snapshot: TabSnapshot? = nil
    var timing: BridgeTiming? = nil
    var stages: SwitchStages? = nil
    var switched: Bool = false
    var error: String? = nil
}

// NSAppleScript runs on the helper's main thread. The UI never waits for Safari.
// One persistent helper avoids launching osascript for each poll or shortcut.
final class SafariBridge {
    private let queue = DispatchQueue(label: "SafariRecentTabs.bridge", qos: .userInitiated)
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var buffer = Data()

    func request(_ request: BridgeRequest, completion: @escaping (BridgeReply) -> Void) {
        let enqueuedAt = ProcessInfo.processInfo.systemUptime
        queue.async {
            let startedAt = ProcessInfo.processInfo.systemUptime
            var reply: BridgeReply
            do {
                if self.process?.isRunning != true { try self.start() }
                var data = try JSONEncoder().encode(request)
                data.append(10)
                try self.input?.write(contentsOf: data)
                while !self.buffer.contains(10) {
                    guard let chunk = self.output?.availableData, !chunk.isEmpty else {
                        throw NSError(domain: "Bridge", code: 1, userInfo: [NSLocalizedDescriptionKey: "Safari helper stopped."])
                    }
                    self.buffer.append(chunk)
                }
                let end = self.buffer.firstIndex(of: 10)!
                let line = self.buffer.prefix(upTo: end)
                reply = try JSONDecoder().decode(BridgeReply.self, from: line)
                self.buffer.removeSubrange(...end)
            } catch {
                self.process?.terminate()
                self.process = nil
                reply = BridgeReply(error: error.localizedDescription)
            }
            let finishedAt = ProcessInfo.processInfo.systemUptime
            let completedReply = reply
            DispatchQueue.main.async {
                var delivered = completedReply
                delivered.timing = BridgeTiming(queueMS: (startedAt - enqueuedAt) * 1000,
                    helperMS: (finishedAt - startedAt) * 1000,
                    callbackMS: (ProcessInfo.processInfo.systemUptime - finishedAt) * 1000)
                completion(delivered)
            }
        }
    }
    private func start() throws {
        let child = Process()
        child.executableURL = Bundle.main.executableURL
        child.arguments = ["--bridge"]
        let incoming = Pipe(), outgoing = Pipe()
        child.standardInput = incoming
        child.standardOutput = outgoing
        child.standardError = FileHandle.nullDevice
        try child.run()
        input = incoming.fileHandleForWriting
        output = outgoing.fileHandleForReading
        buffer.removeAll(keepingCapacity: true)
        process = child
    }
    func stop() {
        queue.async {
            try? self.input?.close()
            self.process?.terminate()
            self.process = nil
        }
    }
}

// Safari terminology comes from Safari.sdef; object-specifier fields are standard
// Apple event codes. Building these locally avoids implicit AppleScript lookups.
enum SafariEvents {
    static func code(_ value: String) -> OSType {
        precondition(value.utf8.count == 4)
        return value.utf8.reduce(0) { ($0 << 8) | OSType($1) }
    }
    static func object(_ kind: String, form: String, key: NSAppleEventDescriptor,
                       container: NSAppleEventDescriptor = .null()) -> NSAppleEventDescriptor {
        let record = NSAppleEventDescriptor.record()
        record.setDescriptor(NSAppleEventDescriptor(typeCode: code(kind)), forKeyword: code("want"))
        record.setDescriptor(NSAppleEventDescriptor(enumCode: code(form)), forKeyword: code("form"))
        record.setDescriptor(key, forKeyword: code("seld"))
        record.setDescriptor(container, forKeyword: code("from"))
        return record.coerce(toDescriptorType: code("obj "))!
    }
    static func property(_ name: String, of container: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        object("prop", form: "prop", key: NSAppleEventDescriptor(typeCode: code(name)), container: container)
    }
    static func event(_ command: String, object: NSAppleEventDescriptor,
                      value: NSAppleEventDescriptor? = nil) -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(eventClass: code("core"), eventID: code(command),
            targetDescriptor: NSAppleEventDescriptor(bundleIdentifier: "com.apple.Safari"),
            returnID: -1, transactionID: 0)
        event.setParam(object, forKeyword: code("----"))
        if let value { event.setParam(value, forKeyword: code("data")) }
        return event
    }
    static func send(_ event: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor {
        let reply = try event.sendEvent(options: [.waitForReply], timeout: 3)
        if let number = reply.paramDescriptor(forKeyword: code("errn")), number.int32Value != 0 {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(number.int32Value), userInfo: [
                NSLocalizedDescriptionKey: reply.paramDescriptor(forKeyword: code("errs"))?.stringValue ?? "Safari automation failed."
            ])
        }
        return reply.paramDescriptor(forKeyword: code("----")) ?? .null()
    }
}

final class SafariScripts {
    let reader = NSAppleScript(source: """
    with timeout of 2 seconds
        tell application "/Applications/Safari.app"
            if (count of windows) is 0 then return {}
            set w to front window
            return {id of w, index of current tab of w, URL of every tab of w, name of every tab of w}
        end tell
    end timeout
    """)!
    private let send: (NSAppleEventDescriptor) throws -> NSAppleEventDescriptor

    init(send: @escaping (NSAppleEventDescriptor) throws -> NSAppleEventDescriptor = SafariEvents.send) {
        self.send = send
    }

    static func targetIndex(urls: [String], index: Int, expectedURL: String) -> Result<Int, SelectionError> {
        if urls.indices.contains(index), urls[index] == expectedURL { return .success(index) }
        var match: Int?
        for i in urls.indices where urls[i] == expectedURL {
            if match != nil { return .failure(.ambiguous) }
            match = i
        }
        guard let match else { return .failure(.missing) }
        return .success(match)
    }

    enum SelectionError: String, Error {
        case ambiguous = "The tab moved and its address is duplicated. Try again."
        case missing = "The selected tab closed or navigated. Try again."
    }

    func execute(_ request: BridgeRequest) -> BridgeReply {
        var error: NSDictionary?
        if request.action == "check" {
            let ok = reader.compileAndReturnError(&error)
            return BridgeReply(switched: ok, error: error?.description)
        }
        if request.action == "read" {
            let result = reader.executeAndReturnError(&error)
            if let error { return BridgeReply(error: error.description) }
            guard result.numberOfItems == 4, let urls = result.atIndex(3), let titles = result.atIndex(4) else { return BridgeReply() }
            var tabs: [TabInfo] = []
            if urls.numberOfItems > 0 {
                for i in 1...urls.numberOfItems {
                    tabs.append(TabInfo(url: urls.atIndex(i)?.stringValue ?? "", title: titles.atIndex(i)?.stringValue ?? "Untitled tab"))
                }
            }
            return BridgeReply(snapshot: TabSnapshot(windowID: Int(result.atIndex(1)?.int32Value ?? 0),
                selected: Int(result.atIndex(2)?.int32Value ?? 0) - 1, tabs: tabs))
        }
        guard request.action == "select", let windowID = request.windowID, let index = request.index,
              index >= 0, index < Int(Int32.max), let expectedURL = request.expectedURL,
              Int32(exactly: windowID) != nil else { return BridgeReply(error: "Invalid selection") }
        var stages = SwitchStages()
        func reply(_ switched: Bool = false, error: String? = nil) -> BridgeReply {
            BridgeReply(stages: stages, switched: switched, error: error)
        }
        var stageStart = ProcessInfo.processInfo.systemUptime
        var stage = 0
        func elapsed() -> Double { (ProcessInfo.processInfo.systemUptime - stageStart) * 1000 }
        do {
            let front = SafariEvents.object("cwin", form: "indx", key: NSAppleEventDescriptor(int32: 1))
            let actualID = try send(SafariEvents.event("getd", object: SafariEvents.property("ID  ", of: front)))
            guard actualID.int32Value == Int32(windowID) else {
                stages.validationMS = elapsed()
                return reply(error: "The active Safari window changed.")
            }
            let window = SafariEvents.object("cwin", form: "ID  ", key: NSAppleEventDescriptor(int32: Int32(windowID)))
            let allTabs = SafariEvents.object("bTab", form: "indx",
                key: NSAppleEventDescriptor(descriptorType: SafariEvents.code("abso"),
                    data: NSAppleEventDescriptor(enumCode: SafariEvents.code("all ")).data)!, container: window)
            let urlsDescriptor = try send(SafariEvents.event("getd", object: SafariEvents.property("pURL", of: allTabs)))
            guard urlsDescriptor.descriptorType == SafariEvents.code("list") else {
                stages.validationMS = elapsed()
                return reply(error: "Safari returned no tab list.")
            }
            let urls = (0..<urlsDescriptor.numberOfItems).map { urlsDescriptor.atIndex($0 + 1)?.stringValue ?? "" }
            let target: Int
            switch Self.targetIndex(urls: urls, index: index, expectedURL: expectedURL) {
            case .success(let found): target = found
            case .failure(let reason):
                stages.validationMS = elapsed()
                return reply(error: reason.rawValue)
            }
            stages.validationMS = elapsed()

            stage = 1
            stageStart = ProcessInfo.processInfo.systemUptime
            let currentTab = SafariEvents.property("cTab", of: window)
            let targetTab = SafariEvents.object("bTab", form: "indx",
                key: NSAppleEventDescriptor(int32: Int32(target + 1)), container: window)
            _ = try send(SafariEvents.event("setd", object: currentTab, value: targetTab))
            stages.selectionMS = elapsed()

            stage = 2
            stageStart = ProcessInfo.processInfo.systemUptime
            let result = try send(SafariEvents.event("getd", object: SafariEvents.property("pidx", of: currentTab)))
            stages.verificationMS = elapsed()
            let switched = Int(result.int32Value) == target + 1
            return reply(switched, error: switched ? nil : "Safari did not select the requested tab.")
        } catch {
            switch stage {
            case 0: stages.validationMS = elapsed()
            case 1: stages.selectionMS = elapsed()
            default: stages.verificationMS = elapsed()
            }
            return reply(error: error.localizedDescription)
        }
    }
}

func runBridge() {
    let scripts = SafariScripts()
    while let line = readLine() {
        autoreleasepool {
            let reply: BridgeReply
            do { reply = scripts.execute(try JSONDecoder().decode(BridgeRequest.self, from: Data(line.utf8))) }
            catch { reply = BridgeReply(error: error.localizedDescription) }
            if var data = try? JSONEncoder().encode(reply) {
                data.append(10)
                FileHandle.standardOutput.write(data)
            }
        }
    }
}
