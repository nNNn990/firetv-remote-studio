import Foundation
import FireTVCore

var failures = 0, passes = 0
func expect(_ cond: Bool, _ what: String, file: String = #fileID, line: Int = #line) {
    if cond { passes += 1; print("PASS \(what)") } else { failures += 1; print("FAIL \(what)  (\(file):\(line))") }
}
func section(_ s: String) { print("\n== \(s) ==") }

// MARK: 1. Original 22 tests (unchanged semantics)
section("legacy parser (original 22)")
for (code, name) in legacyButtonMap.sorted(by: { $0.key < $1.key }) {
    expect(parseReport(reportID: 0xEF, bytes: [0xEF, code, 0, 0]) == .button(code), "with-ID layout \(name)")
    expect(parseReport(reportID: 0xEF, bytes: [code, 0, 0]) == .button(code), "without-ID layout \(name)")
}
expect(parseReport(reportID: 0xEF, bytes: [0xEF, 0, 0, 0]) == .released, "release parsed")
do { let t = PressTracker(); expect(t.feed(.released) == nil, "release fires nothing") }
expect(parseReport(reportID: 0x02, bytes: [0x02, 0x8d, 0, 0, 0]) == .ignored, "TV button report ignored")
expect(parseReport(reportID: 0x01, bytes: [0, 0, 0x4f, 0, 0, 0, 0, 0]) == .ignored, "keyboard report ignored")
expect(parseReport(reportID: 0xEF, bytes: []) == .ignored, "empty buffer")
expect(parseReport(reportID: 0xEF, bytes: [0xEF]) == .ignored, "1-byte buffer")
expect(parseReport(reportID: 0xEF, bytes: [0xA1]) == .button(0xA1), "1-byte payload")
expect(parseReport(reportID: 0xEF, bytes: [0xEF, 0x77, 0, 0]) == .unknown(0x77), "unknown code")
do {
    let t2 = PressTracker()
    expect(t2.feed(.button(0xA1)) == 0xA1, "first A1 fires")
    expect(t2.feed(.button(0xA1)) == nil, "repeat A1 does not fire")
    expect(t2.feed(.released) == nil, "release")
    expect(t2.feed(.button(0xA1)) == 0xA1, "A1 after release fires again")
    expect(t2.feed(.button(0xA2)) == 0xA2, "direct A1->A2 fires A2")
    expect(t2.feed(.unknown(0x77)) == nil, "unknown never fires")
}

// MARK: 2. Generic decoding + state tracker
section("generic decoder")
func st(_ rid: UInt8, _ codes: [UInt16]) -> RemoteEvent { .state(reportID: rid, pressed: codes.map { ButtonCode(reportID: rid, code: $0) }) }
expect(decodeReport(reportID: 0xEF, bytes: [0xEF, 0xA3, 0, 0]) == st(0xEF, [0xA3]), "vendor press with ID")
expect(decodeReport(reportID: 0xEF, bytes: [0xA3, 0, 0]) == st(0xEF, [0xA3]), "vendor press without ID")
expect(decodeReport(reportID: 0x01, bytes: [0x01, 0x52, 0, 0]) == st(0x01, [0x52]), "keyboard up arrow")
expect(decodeReport(reportID: 0x02, bytes: [0x02, 0x8d, 0, 0, 0]) == st(0x02, [0x8d]), "consumer TV")
expect(decodeReport(reportID: 0x02, bytes: [0x02, 0, 0, 0, 0]) == st(0x02, []), "consumer release")
expect(decodeReport(reportID: 0x02, bytes: [0x02, 0xea, 0, 0xe9, 0]) == st(0x02, [0xea, 0xe9]), "two consumer keys held at once (real log: ea 00 e9 00)")
expect(decodeReport(reportID: 0x01, bytes: [0x01, 0x52, 0x50, 0]) == st(0x01, [0x52, 0x50]), "two keyboard keys at once")
expect(decodeReport(reportID: 0x05, bytes: [0x05, 0x11]) == .ignored, "unknown report id ignored")
expect(decodeReport(reportID: 0xEF, bytes: []) == .ignored, "empty ignored")
expect(decodeReport(reportID: 0xEF, bytes: [0xEF]) == .ignored, "id-only ignored")
do {
    let t = ButtonStateTracker()
    let a1 = ButtonCode(reportID: 0xEF, code: 0xA1), a2 = ButtonCode(reportID: 0xEF, code: 0xA2), up = ButtonCode(reportID: 0x01, code: 0x52)
    expect(t.feed(.state(reportID: 0xEF, pressed: [a1])) == [.press(a1)], "tracker press")
    expect(t.feed(.state(reportID: 0xEF, pressed: [a1])) == [], "tracker duplicate press ignored")
    expect(t.feed(.state(reportID: 0x01, pressed: [up])) == [.press(up)], "other report id independent")
    expect(t.feed(.state(reportID: 0xEF, pressed: [a2])) == [.release(a1), .press(a2)], "switch within report releases previous")
    expect(t.feed(.state(reportID: 0xEF, pressed: [])) == [.release(a2)], "release")
    expect(t.feed(.state(reportID: 0xEF, pressed: [])) == [], "double release ignored")
    expect(t.reset() == [.release(up)], "reset releases held")
    let vdn = ButtonCode(reportID: 2, code: 0xEA), vup = ButtonCode(reportID: 2, code: 0xE9)
    expect(t.feed(.state(reportID: 2, pressed: [vdn])) == [.press(vdn)], "hold volume-")
    expect(t.feed(.state(reportID: 2, pressed: [vdn, vup])) == [.press(vup)], "volume+ pressed while volume- held is detected")
    expect(t.feed(.state(reportID: 2, pressed: [vdn])) == [.release(vup)], "volume+ released, volume- still held")
    expect(t.feed(.state(reportID: 2, pressed: [])) == [.release(vdn)], "volume- released")
}

// MARK: 3. Button table
section("button table")
expect(ButtonTable.info(for: .a1, learned: [:]).restriction == .none, "A1 assignable")
expect(ButtonTable.info(for: .mic, learned: [:], exclusive: true).restriction == .none, "mic assignable in exclusive mode")
expect(ButtonTable.info(for: .mic, learned: [:], exclusive: false).restriction == .osHandled, "mic is OS-handled in normal mode")
expect(ButtonTable.info(for: .tv, learned: [:]).restriction == .none, "TV mark assignable")
expect(ButtonTable.info(for: .up, learned: [:]).restriction == .osHandled, "arrow is OS-handled")
expect(ButtonTable.info(for: .playPause, learned: [:]).restriction == .osHandled, "play is OS-handled")
expect(ButtonTable.info(for: .home, learned: [:]).restriction == .codeUnknown, "home needs learning")
expect(ButtonTable.info(for: .home, learned: [.home: ButtonCode(reportID: 0x02, code: 0x23)]).restriction == .none, "learned consumer code assignable")
expect(ButtonTable.info(for: .home, learned: [.home: ButtonCode(reportID: 0x01, code: 0x29)]).restriction == .osHandled, "learned keyboard code OS-handled")

// MARK: 3b. Supported device models
section("supported remote models")
expect(HIDMonitor.productIDs.contains(0x042F), "3rd gen product ID matched")
expect(HIDMonitor.productIDs.contains(0x0413), "2nd gen product ID matched")
expect(HIDMonitor.modelName(for: 0x0413).contains("2nd Gen"), "2nd gen has a friendly name")
expect(HIDMonitor.modelName(for: 0x042F).contains("3rd Gen"), "3rd gen has a friendly name")
expect(HIDMonitor.modelName(for: 0x1234) == "Amazon Remote", "unknown product ID falls back")

// MARK: 3c. Fn modifier
section("fn key modifier")
do {
    let old = Data(#"{"keyCode":99,"keyName":"F3","command":false,"shift":false,"option":false,"control":false}"#.utf8)
    let oldCombo = try JSONDecoder().decode(KeyCombo.self, from: old)
    expect(!oldCombo.function, "old key combo decodes without fn")
    expect(!oldCombo.modifierOnly, "old key combo decodes without modifier-only")
    let fn = KeyCombo(keyCode: 99, keyName: "F3", function: true)
    expect(fn.display == "fn F3", "fn shown in display")
    expect(try JSONDecoder().decode(KeyCombo.self, from: JSONEncoder().encode(fn)) == fn, "fn round trips through config JSON")
    expect(KeyCombo(keyCode: 99, keyName: "F3").display == "F3", "fn is off by default")
    let fnOnly = KeyCombo(keyCode: 0, keyName: "", function: true, modifierOnly: true)
    expect(fnOnly.display == "fn", "modifier-only fn has no key name")
    expect(try JSONDecoder().decode(KeyCombo.self, from: JSONEncoder().encode(fnOnly)) == fnOnly, "modifier-only round trips")
    expect(KeyCombo(keyCode: 99, keyName: "F3").modifierOnly == false, "modifier-only is off by default")
}

// MARK: 4. Layer engine
section("layer engine")
func layers(_ n: Int) -> [Layer] { (0..<n).map { Layer(name: "L\($0)") } }
do {
    var ls = layers(4)
    ls[0].bindings = [.a1: .shortcut(name: "S0"), .a2: .layer(.momentary(1)), .a3: .layer(.toggle(2)), .a4: .shortcut(name: "A4-L0"), .tv: .layer(.switchTo(3))]
    ls[1].bindings = [.a1: .shortcut(name: "S1"), .a4: .none]
    ls[2].bindings = [.a1: .shortcut(name: "S2")]
    ls[3].bindings = [.a1: .layer(.setDefault(3)), .tv: .layer(.switchTo(0))]
    let e = LayerEngine(layers: ls, defaultLayer: 0)
    expect(e.activeLayers == [0], "initial active layer 0")
    expect(e.press(.a1) == [.execute(.shortcut(name: "S0"))], "L0 action executes")
    expect(e.press(.a1) == [], "duplicate press no re-execute")
    expect(e.release(.a1) == [.release(.shortcut(name: "S0"))], "release of plain action reports the captured action")
    // Transparent inherits, none stops
    expect(e.press(.a2) == [.layerStateChanged], "MO(1) press")
    expect(e.activeLayers == [1, 0], "MO active")
    expect(e.resolve(.a1) == .shortcut(name: "S1"), "L1 overrides")
    expect(e.resolve(.a3) == .layer(.toggle(2)), "transparent falls through to L0")
    expect(e.resolve(.a4) == .none, "explicit none blocks lower layer")
    expect(e.press(.a4) == [], "none executes nothing")
    _ = e.release(.a4)
    expect(e.release(.a2) == [.layerStateChanged], "MO release")
    expect(e.activeLayers == [0], "MO released restores")
    // TG
    expect(e.press(.a3) == [.layerStateChanged] && e.activeLayers == [2, 0], "TG(2) on")
    _ = e.release(.a3)
    expect(e.resolve(.a1) == .shortcut(name: "S2"), "L2 active after toggle")
    _ = e.press(.a3); _ = e.release(.a3)
    expect(e.activeLayers == [0], "TG(2) off")
    // Overlapping MO: a2 held, then TG via a3 while held, release order
    _ = e.press(.a2); _ = e.press(.a3); _ = e.release(.a3)
    expect(e.activeLayers == [2, 1, 0], "MO + TG stacked")
    _ = e.release(.a2)
    expect(e.activeLayers == [2, 0], "MO released, TG stays")
    _ = e.press(.a3); _ = e.release(.a3)
    // Exclusive TG semantics
    do {
        var tl = layers(4)
        tl[0].bindings = [.a1: .layer(.toggle(0)), .a2: .layer(.toggle(1)), .a3: .layer(.toggle(2)), .a4: .layer(.toggle(3))]
        let t = LayerEngine(layers: tl, defaultLayer: 0)
        _ = t.press(.a3); _ = t.release(.a3)
        expect(t.activeLayers == [2, 0], "TG(2) on")
        _ = t.press(.a2); _ = t.release(.a2)
        expect(t.activeLayers == [1, 0], "TG(1) replaces TG(2) (exclusive)")
        _ = t.press(.a1); _ = t.release(.a1)
        expect(t.activeLayers == [0], "TG(default) returns to base")
        _ = t.press(.a4); _ = t.release(.a4); _ = t.press(.a4); _ = t.release(.a4)
        expect(t.activeLayers == [0], "TG(3) twice toggles off")
    }
    // Action captured at press: start MO then release after layer changed
    _ = e.press(.a2)                       // MO(1) active
    _ = e.press(.a1)                       // resolves S1
    _ = e.release(.a2)                     // layer gone
    expect(e.release(.a1) == [.release(.shortcut(name: "S1"))], "release uses the action captured at press time")
    // TO(3) then TO(0) via tv
    expect(e.press(.tv) == [.layerStateChanged] && e.activeLayers == [3, 0], "TO(3)")
    _ = e.release(.tv)
    _ = e.press(.tv); _ = e.release(.tv)   // on L3, tv = TO(0)
    expect(e.activeLayers == [0], "TO(0) returns to base")
    // DF(3)
    _ = e.press(.tv); _ = e.release(.tv)   // TO(3)
    expect(e.press(.a1) == [.defaultLayerChanged(3), .layerStateChanged], "DF(3) effect")
    _ = e.release(.a1)
    expect(e.defaultLayer == 3 && e.activeLayers == [3], "default layer now 3")
    // releaseAll on disconnect clears momentary
    let e2 = LayerEngine(layers: ls, defaultLayer: 0)
    _ = e2.press(.a2)
    expect(e2.isMomentaryActive, "MO held")
    expect(e2.releaseAll() == [.layerStateChanged] && e2.activeLayers == [0], "disconnect clears MO")
    expect(e2.release(.a2) == [], "stale release after disconnect ignored")
    // Out-of-range layer op does nothing
    var bad = layers(2); bad[0].bindings = [.a1: .layer(.momentary(7))]
    let e3 = LayerEngine(layers: bad, defaultLayer: 0)
    expect(e3.press(.a1) == [] && e3.activeLayers == [0], "invalid layer op ignored")
    // update() while a toggle references a removed layer
    e3.update(layers: layers(1), defaultLayer: 5)
    expect(e3.defaultLayer == 0, "update clamps default layer")
}

// MARK: 5. Config / codec / validation
section("config")
do {
    var c = Config.makeDefault(existingShortcuts: ["FireTV-A1", "FireTV-A2", "FireTV-A3", "FireTV-A4", "Other"])
    expect(c.layers.count == 4 && c.layers[0].bindings[.a3] == .shortcut(name: "FireTV-A3"), "legacy migration binds A1–A4")
    expect(Config.makeDefault().layers[0].bindings.isEmpty, "no migration without shortcuts")
    let data = try ConfigCodec.encode(c)
    let back = try ConfigCodec.decode(data)
    expect(back == c, "JSON round trip")
    // japanese / spaces / symbols in names
    c.layers[1].bindings[.a1] = .shortcut(name: "Japanese Name (Test) #1 & \"quote\"")
    expect(try ConfigCodec.decode(try ConfigCodec.encode(c)) == c, "unicode shortcut name round trip")
    // validation
    var bad = c
    bad.layers[0].bindings[.a2] = .layer(.toggle(9)); bad.defaultLayer = 42; bad.layers[0].bindings[.a4] = .transparent
    bad.layers[0].bindings[.tv] = .macro(id: UUID())
    bad.layers[1].bindings[.a1] = .shortcut(name: "")
    let issues = bad.validateAndRepair()
    expect(issues.count == 3, "three issues reported: \(issues)")
    expect(bad.layers[1].bindings[.a1] == .shortcut(name: ""), "empty shortcut name is kept as 'not chosen yet'")
    expect(bad.defaultLayer == 0 && bad.layers[0].bindings[.a2] == Action.none && bad.layers[0].bindings[.a4] == nil && bad.layers[0].bindings[.tv] == Action.none, "repairs applied (transparent on L0 becomes unset)")
    expect((try? ConfigCodec.decode(Data("{not json".utf8))) == nil, "corrupt JSON throws")
    expect((try? ConfigCodec.decode(Data("{}".utf8))) == nil, "empty object throws (missing keys)")
    // layer removal keeps references consistent
    var r = Config(layers: layers(4))
    r.layers[0].bindings = [.a1: .layer(.momentary(1)), .a2: .layer(.toggle(2)), .a3: .layer(.switchTo(3))]
    r.defaultLayer = 3
    expect(r.removeLayer(0) == false, "layer 0 cannot be removed")
    expect(r.removeLayer(2), "remove layer 2")
    expect(r.layers.count == 3 && r.defaultLayer == 2, "default shifted")
    expect(r.layers[0].bindings[.a1] == .layer(.momentary(1)) && r.layers[0].bindings[.a2] == Action.none && r.layers[0].bindings[.a3] == .layer(.switchTo(2)), "references remapped")
    let dup = r.duplicateLayer(0)!
    expect(r.layers[dup].bindings == r.layers[0].bindings && r.layers[dup].id != r.layers[0].id, "duplicate copies bindings with new id")
    r.resetLayer(dup); expect(r.layers[dup].bindings.isEmpty, "reset layer")
    // store: corrupt file quarantined, not crashing
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("firetv-test-\(UUID().uuidString)")
    let store = ConfigStore(url: tmp.appendingPathComponent("config.json"))
    if case .missing = store.load() { expect(true, "missing config") } else { expect(false, "missing config") }
    try store.save(c)
    if case .loaded(let l) = store.load() { expect(l == c, "store round trip") } else { expect(false, "store round trip") }
    try Data("garbage".utf8).write(to: store.url)
    if case .corrupted(_, let q) = store.load() { expect(q != nil && !FileManager.default.fileExists(atPath: store.url.path), "corrupt file quarantined") } else { expect(false, "corrupt detection") }
    try? FileManager.default.removeItem(at: tmp)
}

// MARK: 6. Shortcuts service
section("shortcuts service")
expect(ShortcutsService.parseList("A\nJapanese Shortcut\nName with (symbols) # 1\n\n") == ["A", "Japanese Shortcut", "Name with (symbols) #1"], "list parsing")
do {
    let svc = ShortcutsService()
    let names = try svc.list()
    expect(names.count >= 4 && names.contains("FireTV-A1"), "real `shortcuts list` returns \(names.count) items incl. FireTV-A1")
    let sem = DispatchSemaphore(value: 0); var ok = false
    svc.run("FireTV-A2") { r in if case .success = r { ok = true }; sem.signal() }
    _ = sem.wait(timeout: .now() + 20)
    expect(ok, "real run of FireTV-A2 succeeds")
    let sem2 = DispatchSemaphore(value: 0); var err: Error?
    svc.run("This shortcut does not exist -\(UUID () .uuidString.prefix (4))") { r in if case .failure(let e) = r { err = e }; sem2.signal() }
    _ = sem2.wait(timeout: .now() + 20)
    expect(err != nil, "missing shortcut reports failure: \(err?.localizedDescription ?? "")")
    // double-run guard
    let sem3 = DispatchSemaphore(value: 0); var results: [Bool] = []; let lock = NSLock()
    svc.run("FireTV-A3") { r in lock.lock(); results.append((try? r.get()) != nil); lock.unlock(); sem3.signal() }
    svc.run("FireTV-A3") { r in lock.lock(); results.append((try? r.get()) != nil); lock.unlock(); sem3.signal() }
    _ = sem3.wait(timeout: .now() + 20); _ = sem3.wait(timeout: .now() + 20)
    expect(results.filter { $0 }.count == 1 && results.count == 2, "second concurrent run of same shortcut refused")
}

// MARK: 6b. Exclusive-mode pieces
section("16-bit consumer usages / passthrough / unset vs disabled")
expect(decodeReport(reportID: 0x02, bytes: [0x02, 0x23, 0x02, 0, 0]) == st(0x02, [0x0223]), "AC Home decodes as 0x0223")
expect(decodeReport(reportID: 0x02, bytes: [0x02, 0xE9, 0x00, 0, 0]) == st(0x02, [0x00E9]), "volume up decodes as 0x00E9")
expect(decodeReport(reportID: 0x01, bytes: [0x01, 0x52, 0, 0]) == st(0x01, [0x52]), "keyboard stays 8-bit")
expect(ButtonCode(reportID: 2, code: 0x23).matches(ButtonCode(reportID: 2, code: 0x0223)), "legacy low-byte learned code matches 16-bit usage")
expect(!ButtonCode(reportID: 1, code: 0x23).matches(ButtonCode(reportID: 2, code: 0x0223)), "different report id never matches")
expect(ButtonTable.info(for: .up, learned: [:], exclusive: true).restriction == .none, "exclusive mode lifts OS-handled restriction")
expect(ButtonTable.info(for: .up, learned: [:], exclusive: false).restriction == .osHandled, "normal mode keeps restriction")
expect(PassthroughEmitter.mapping(for: ButtonCode(reportID: 2, code: 0xE9))?.label == "Volume Up", "volume+ maps to media key")
expect(PassthroughEmitter.mapping(for: ButtonCode(reportID: 1, code: 0x52))?.label == "↑", "up arrow maps to key")
expect(PassthroughEmitter.mapping(for: ButtonCode(reportID: 2, code: 0x0223)) == nil, "AC Home has no macOS default")
expect(PassthroughEmitter.mapping(for: ButtonCode(reportID: 0xEF, code: 0xA1)) == nil, "vendor keys have no default")
do {
    var ls = layers(2)
    ls[0].bindings = [.volumeUp: .shortcut(name: "S"), .mute: Action.none, .up: .passthrough]
    ls[1].bindings = [.volumeUp: .passthrough]
    let e = LayerEngine(layers: ls, defaultLayer: 0)
    expect(e.resolveBinding(.volumeDown) == nil && e.resolve(.volumeDown) == .passthrough, "unset → passthrough (default behaviour)")
    expect(e.resolve(.mute) == Action.none, "explicit none is disabled, not default")
    expect(e.press(.volumeDown) == [.execute(.passthrough)] && e.release(.volumeDown) == [.release(.passthrough)], "passthrough press/release effects")
    expect(e.press(.mute) == [] && e.release(.mute) == [], "disabled button does nothing")
    expect(e.press(.volumeUp) == [.execute(.shortcut(name: "S"))], "L0 custom action")
    _ = e.release(.volumeUp)
    e.update(layers: ls, defaultLayer: 1)
    expect(e.resolve(.volumeUp) == .passthrough, "L1 explicit default overrides L0 custom")
    _ = e.press(.volumeDown)
    expect(e.releaseAll().contains(.release(.passthrough)), "releaseAll releases held passthrough")
}
do {
    var c = Config(layers: layers(2))
    c.layers[0].bindings[.volumeUp] = .passthrough
    c.layers[1].bindings[.mute] = Action.none
    let back = try ConfigCodec.decode(try ConfigCodec.encode(c))
    expect(back == c, "passthrough / none round trip")
    expect(UISettings().exclusiveCapture == nil, "old configs decode without exclusive flag")
}

// MARK: 6c. Mic upsampler
section("upsampler 16k->48k")
do {
    // 1 kHz sine at 16 kHz, 100 ms
    let n = 1600
    let input = (0..<n).map { Int16(10000 * sin(2 * Double.pi * 1000 * Double($0) / 16000)) }
    var one = Upsampler3x(); var outA = [Float](repeating: 0, count: n * 3)
    let ca = one.process(input, count: n, into: &outA)
    var chunked = Upsampler3x(); var outB = [Float](repeating: 0, count: n * 3); var pos = 0
    for start in stride(from: 0, to: n, by: 320) {           // packet-sized chunks
        var tmp = [Float](repeating: 0, count: 960)
        let c = chunked.process(Array(input[start..<min(start + 320, n)]), count: min(320, n - start), into: &tmp)
        for i in 0..<c { outB[pos + i] = tmp[i] }; pos += c
    }
    expect(ca == n * 3 && pos == n * 3, "3x output length")
    var maxDiff: Float = 0; for i in 0..<ca { maxDiff = max(maxDiff, abs(outA[i] - outB[i])) }
    expect(maxDiff < 1e-6, "chunked == one-shot (no boundary discontinuity), maxDiff=\(maxDiff)")
    func mag(_ x: [Float], _ f: Double) -> Double { var re = 0.0, im = 0.0; for i in 200..<x.count { re += Double(x[i]) * cos(2 * .pi * f * Double(i) / 48000); im += Double(x[i]) * sin(2 * .pi * f * Double(i) / 48000) }; return sqrt(re * re + im * im) / Double(x.count - 200) }
    let m1k = mag(outA, 1000), m15k = mag(outA, 15000), m17k = mag(outA, 17000)
    expect(m1k > 0.12 && m1k < 0.18, "1 kHz passes with unity gain (\(m1k), expect ≈0.153)")
    expect(m15k < m1k * 0.01 && m17k < m1k * 0.01, "images at 15/17 kHz suppressed > 40 dB (\(m15k), \(m17k))")
}

// MARK: 6d. Key hold semantics through the engine
section("key hold")
do {
    var ls = layers(1); ls[0].bindings = [.mic: .key(KeyCombo(keyCode: 49, keyName: "Space", command: true))]
    let e = LayerEngine(layers: ls, defaultLayer: 0)
    expect(e.press(.mic) == [.execute(.key(KeyCombo(keyCode: 49, keyName: "Space", command: true)))], "press → key down effect")
    expect(e.release(.mic) == [.release(.key(KeyCombo(keyCode: 49, keyName: "Space", command: true)))], "release → key up effect")
}

// MARK: 7. Controller end-to-end (synthetic reports, temp store, dry executor)
section("controller")
do {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("firetv-ctl-\(UUID().uuidString)")
    let store = ConfigStore(url: tmp.appendingPathComponent("config.json"))
    let ctl = RemoteController(store: store, monitor: HIDMonitor(), shortcuts: ShortcutsService())
    ctl.setMonitoring(false)
    var executed: [String] = []
    ctl.executor.onEvent = { e in if case .started(let s) = e { executed.append(s) } }
    func pump() { RunLoop.main.run(until: Date().addingTimeInterval(0.3)) }
    ctl.assign(.shortcut(name: "FireTV-A1"), to: .a1, layer: 0)
    ctl.assign(.layer(.momentary(1)), to: .a2, layer: 0)
    ctl.assign(.shortcut(name: "FireTV-A4"), to: .a1, layer: 1)
    ctl.assign(.openURL("https://example.com"), to: .tv, layer: 0)
    // A1 on layer 0
    ctl.inject(reportID: 0xEF, bytes: [0xEF, 0xA1, 0, 0]); ctl.inject(reportID: 0xEF, bytes: [0xEF, 0xA1, 0, 0]); ctl.inject(reportID: 0xEF, bytes: [0xEF, 0, 0, 0])
    pump()
    expect(executed == ["Shortcut FireTV-A1"], "A1 executes once despite repeat report")
    expect(ctl.lastPressed == .a1, "lastPressed updated")
    // hold A2 (MO1), press A1 → layer 1 binding
    ctl.inject(reportID: 0xEF, bytes: [0xEF, 0xA2, 0, 0])
    expect(ctl.activeLayers == [1, 0], "MO via HID")
    ctl.inject(reportID: 0xEF, bytes: [0xEF, 0, 0, 0])   // wire: only one vendor button at a time → release A2
    expect(ctl.activeLayers == [0], "MO release via HID")
    // OS-handled key never executes
    ctl.assign(.shortcut(name: "FireTV-A3"), to: .up, layer: 0)   // GUI blocks this, but engine must still refuse
    ctl.inject(reportID: 0x01, bytes: [0x01, 0x52, 0, 0]); ctl.inject(reportID: 0x01, bytes: [0x01, 0, 0, 0])
    pump()
    expect(executed.count == 1 && ctl.lastPressed == .up, "arrow identified but not executed")
    // unknown code logged, learn mode binds it
    ctl.inject(reportID: 0x02, bytes: [0x02, 0x23, 0, 0, 0]); ctl.inject(reportID: 0x02, bytes: [0x02, 0, 0, 0, 0])
    expect(ctl.lastUnknownCode == ButtonCode(reportID: 2, code: 0x23), "unknown code captured")
    ctl.learningButton = .home
    ctl.inject(reportID: 0x02, bytes: [0x02, 0x23, 0, 0, 0]); ctl.inject(reportID: 0x02, bytes: [0x02, 0, 0, 0, 0])
    expect(ctl.config.learnedCodes[.home] == ButtonCode(reportID: 2, code: 0x23) && ctl.learningButton == nil, "learn mode binds home")
    expect(ctl.info(for: .home).restriction == .none, "learned home assignable")
    // persistence
    ctl.saveNow()
    let ctl2 = RemoteController(store: store, monitor: HIDMonitor(), shortcuts: ShortcutsService())
    ctl2.setMonitoring(false)
    expect(ctl2.config.layers[1].bindings[.a1] == .shortcut(name: "FireTV-A4") && ctl2.config.learnedCodes[.home] != nil, "config persisted across restart")
    // missing shortcut warning
    ctl2.assign(.shortcut(name: "Nonexistent shortcut"), to: .a4, layer: 0)
    let deadline = Date().addingTimeInterval(10)
    while ctl2.shortcutNames.isEmpty && ctl2.shortcutsLoadError == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
    expect(ctl2.missingShortcuts == ["Nonexistent shortcut"], "missing shortcut detected")
    // corrupted file recovery
    try Data("{{{".utf8).write(to: store.url)
    let ctl3 = RemoteController(store: store, monitor: HIDMonitor(), shortcuts: ShortcutsService())
    ctl3.setMonitoring(false)
    expect(ctl3.startupNotices.contains { $0.contains("Corrupted") } && ctl3.config.layers.count == 4, "corrupt config → defaults + notice")
    try? FileManager.default.removeItem(at: tmp)
}

print("\n\(passes) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
