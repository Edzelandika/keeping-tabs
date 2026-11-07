import Foundation

@main struct SafariEventsTests {
    static func main() {
        let c = SafariEvents.code
        func field(_ d: NSAppleEventDescriptor, _ key: String) -> NSAppleEventDescriptor {
            d.forKeyword(c(key))!
        }
        func urls(_ values: [String]) -> NSAppleEventDescriptor {
            let list = NSAppleEventDescriptor.list()
            for (i, value) in values.enumerated() { list.insert(NSAppleEventDescriptor(string: value), at: i + 1) }
            return list
        }
        func run(_ responses: [NSAppleEventDescriptor], index: Int = 1, url: String = "b") -> (BridgeReply, [NSAppleEventDescriptor]) {
            var requests: [NSAppleEventDescriptor] = []
            let scripts = SafariScripts(send: { event in
                requests.append(event)
                precondition(requests.count <= responses.count, "Unexpected extra Safari message")
                return responses[requests.count - 1]
            })
            let result = scripts.execute(BridgeRequest(action: "select", windowID: 42, index: index, expectedURL: url))
            return (result, requests)
        }
        let (success, events) = run([.init(int32: 42), urls(["a", "b"]), .null(), .init(int32: 2)])
        assert(success.switched && success.error == nil && success.stages != nil)
        assert(events.count == 4)
        assert(events.map(\.eventID) == [c("getd"), c("getd"), c("setd"), c("getd")])
        assert(events.allSatisfy { $0.eventClass == c("core") })
        let frontID = events[0].paramDescriptor(forKeyword: c("----"))!
        assert(field(frontID, "seld").typeCodeValue == c("ID  "))
        assert(field(field(frontID, "from"), "seld").int32Value == 1)
        let allURLs = events[1].paramDescriptor(forKeyword: c("----"))!
        let allTabs = field(allURLs, "from")
        assert(field(allTabs, "seld").descriptorType == c("abso"))
        assert(field(field(allTabs, "from"), "seld").int32Value == 42)
        let destination = events[2].paramDescriptor(forKeyword: c("----"))!
        let target = events[2].paramDescriptor(forKeyword: c("data"))!
        assert(field(destination, "seld").typeCodeValue == c("cTab"))
        assert(field(target, "want").typeCodeValue == c("bTab"))
        assert(field(target, "seld").int32Value == 2)
        let verification = events[3].paramDescriptor(forKeyword: c("----"))!
        assert(field(verification, "seld").typeCodeValue == c("pidx"))
        assert(field(field(verification, "from"), "seld").typeCodeValue == c("cTab"))

        let (moved, movedEvents) = run([.init(int32: 42), urls(["b", "a"]), .null(), .init(int32: 1)])
        assert(moved.switched)
        assert(field(movedEvents[2].paramDescriptor(forKeyword: c("data"))!, "seld").int32Value == 1)
        let (wrongWindow, wrongEvents) = run([.init(int32: 99)])
        assert(!wrongWindow.switched && wrongEvents.count == 1)
        let (closed, closedEvents) = run([.init(int32: 42), urls(["a"])])
        assert(!closed.switched && closedEvents.count == 2)
        let (ambiguous, ambiguousEvents) = run([.init(int32: 42), urls(["b", "a", "b"])])
        assert(!ambiguous.switched && ambiguousEvents.count == 2)
        let (notSelected, _) = run([.init(int32: 42), urls(["a", "b"]), .null(), .init(int32: 1)])
        assert(!notSelected.switched && notSelected.error != nil)
        let failure = SafariScripts(send: { _ in throw NSError(domain: NSOSStatusErrorDomain, code: -1743) })
        assert(!failure.execute(BridgeRequest(action: "select", windowID: 42, index: 1, expectedURL: "b")).switched)
        print("PASS: four-event switch, exact object references, moved/closed/ambiguous tabs, changed window, verification mismatch, and transport errors")
    }
}
