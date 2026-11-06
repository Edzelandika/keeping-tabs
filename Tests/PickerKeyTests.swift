import Foundation
@main struct Tests {
 static func main() {
  assert(PickerKey.action(for:125) == .move(1))
  assert(PickerKey.action(for:126) == .move(-1))
  assert(PickerKey.action(for:36) == .commit)
  assert(PickerKey.action(for:76) == .commit)
  assert(PickerKey.action(for:53) == .cancel)
  assert(PickerKey.action(for:0) == nil)
  var tabs = RecentTabs()
  tabs.observe(TabSnapshot(windowID:1, selected:0, tabs:[TabInfo(url:"a",title:"A"),TabInfo(url:"b",title:"B"),TabInfo(url:"c",title:"C")]))
  assert(tabs.target(step: -1) == 2)
  assert(tabs.target(step: 3) == 0)
  print("PASS: arrow, Enter, Escape, unrelated keys, and wraparound")
 }
}
