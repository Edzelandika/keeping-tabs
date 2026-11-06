import Foundation

struct BridgeRequest: Codable {
    var action: String
    var windowID: Int? = nil
    var index: Int? = nil
    var expectedURL: String? = nil
}
struct BridgeReply: Codable {
    var snapshot: TabSnapshot? = nil
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
        queue.async {
            let reply: BridgeReply
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
            DispatchQueue.main.async { completion(reply) }
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
    let selector = NSAppleScript(source: """
    on selecttab(windowID, newIndex, expectedURL)
        with timeout of 3 seconds
            tell application "/Applications/Safari.app"
                if (count of windows) is 0 then return {false, "Safari has no open window."}
                set w to front window
                if id of w is not windowID then return {false, "The active Safari window changed."}
                if newIndex > 0 and newIndex <= (count of tabs of w) then
                    set candidateURL to URL of tab newIndex of w
                    if candidateURL is missing value then set candidateURL to ""
                    if candidateURL is expectedURL then
                        set current tab of w to tab newIndex of w
                        if (index of current tab of w) is newIndex then return {true, ""}
                        return {false, "Safari did not select the requested tab."}
                    end if
                end if
                set actualURLs to URL of every tab of w
                repeat with i from 1 to count of actualURLs
                    if item i of actualURLs is missing value then set item i of actualURLs to ""
                end repeat
                set targetIndex to 0
                if newIndex > 0 and newIndex <= (count of actualURLs) then
                    if item newIndex of actualURLs is expectedURL then set targetIndex to newIndex
                end if
                if targetIndex is 0 then
                    repeat with i from 1 to count of actualURLs
                        if item i of actualURLs is expectedURL then
                            if targetIndex is not 0 then return {false, "The tab moved and its address is duplicated. Try again."}
                            set targetIndex to i as integer
                        end if
                    end repeat
                end if
                if targetIndex is 0 then return {false, "The selected tab closed or navigated. Try again."}
                set current tab of w to tab targetIndex of w
                if (index of current tab of w) is not targetIndex then return {false, "Safari did not select the requested tab."}
                return {true, ""}
            end tell
        end timeout
    end selecttab
    """)!

    func execute(_ request: BridgeRequest) -> BridgeReply {
        var error: NSDictionary?
        if request.action == "check" {
            let ok = reader.compileAndReturnError(&error) && selector.compileAndReturnError(&error)
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
        let event = NSAppleEventDescriptor(eventClass: 0x61736372, eventID: 0x70736272,
            targetDescriptor: nil, returnID: -1, transactionID: 0) // ascr / psbr
        event.setParam(NSAppleEventDescriptor(string: "selecttab"), forKeyword: 0x736e616d) // snam
        let args = NSAppleEventDescriptor.list()
        args.insert(NSAppleEventDescriptor(int32: Int32(windowID)), at: 1)
        args.insert(NSAppleEventDescriptor(int32: Int32(index + 1)), at: 2)
        args.insert(NSAppleEventDescriptor(string: expectedURL), at: 3)
        event.setParam(args, forKeyword: 0x2d2d2d2d) // direct arguments
        let result = selector.executeAppleEvent(event, error: &error)
        if let error { return BridgeReply(error: error.description) }
        let switched = result.atIndex(1)?.booleanValue ?? false
        let reason = result.atIndex(2)?.stringValue
        return BridgeReply(switched: switched, error: switched ? nil : (reason ?? "Safari returned no switch result."))
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
