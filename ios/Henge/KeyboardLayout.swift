import UIKit

/// macOS's keyboard layout follows this device's keyboard. Henge names the layout for the keyboard's language
/// (host/share.c serves it), the helper in macOS selects it and sends back what each key types there
/// (tools/henge-agent.m), and text is typed through that (KeyMap). Without the helper, nothing changes: macOS keeps
/// its layout and text is typed for U.S. (Keys).
enum KeyboardLayout {
    /// macOS's input source for a keyboard language (UITextInputMode.primaryLanguage, e.g. "de-DE"). nil leaves
    /// macOS as it is: an unknown language, emoji, dictation. An ID macOS doesn't have is ignored by the helper.
    static func macLayout(forLanguage language: String) -> String? {
        let tag = language.replacingOccurrences(of: "_", with: "-")
        let byRegion: [String: String] = [
            "de-CH": "com.apple.keylayout.SwissGerman", "fr-CH": "com.apple.keylayout.SwissFrench",
            "en-GB": "com.apple.keylayout.British", "en-AU": "com.apple.keylayout.Australian",
            "en-IE": "com.apple.keylayout.Irish", "fr-CA": "com.apple.keylayout.Canadian-CSA",
        ]
        if let id = byRegion[tag] { return id }
        let byLanguage: [String: String] = [
            "en": "com.apple.keylayout.US", "de": "com.apple.keylayout.German", "fr": "com.apple.keylayout.French",
            "es": "com.apple.keylayout.Spanish-ISO", "it": "com.apple.keylayout.Italian",
            "pt": "com.apple.keylayout.Portuguese", "nl": "com.apple.keylayout.Dutch",
            "sv": "com.apple.keylayout.Swedish-Pro", "da": "com.apple.keylayout.Danish",
            "nb": "com.apple.keylayout.Norwegian", "fi": "com.apple.keylayout.Finnish",
            "pl": "com.apple.keylayout.PolishPro", "cs": "com.apple.keylayout.Czech",
        ]
        return byLanguage[String(tag.prefix { $0 != "-" })]
    }

    private static var sent: String?

    /// Asks for the layout of a keyboard language, if it is a new one.
    static func follow(language: String?) {
        guard let language, let id = macLayout(forLanguage: language), id != sent else { return }
        sent = id
        henge_share_set_keyboard_layout(id)
        HengeLog.log("keyboard", "keyboard \(language): macOS layout \(id)")
    }

    /// When a Mac starts: the first keyboard in this device's list, until the on-screen one says otherwise. Until
    /// the helper starts (after login), text is typed through the table it sent last time, so a password typed at
    /// the login window gets the layout macOS was left on.
    static func start(_ mac: VirtualMac) {
        sent = nil
        KeyMap.start(saved: mac.directory.appendingPathComponent("keymap.txt"))
        follow(language: UITextInputMode.activeInputModes.first?.primaryLanguage)
    }
}

/// What each key types on macOS's current layout, from the helper: how to type a character there.
enum KeyMap {
    struct Stroke {
        let usage: UInt8
        let shift: Bool
        let option: Bool
    }

    private static var seq: UInt = 0
    private static var table: [Character: [Stroke]] = [:]
    private static var layoutID = ""
    private static var savedFile: URL?

    /// A Mac is starting: its last table, if it has one.
    static func start(saved file: URL) {
        savedFile = file
        table = [:]
        if let text = try? String(contentsOf: file, encoding: .utf8) { parse(text) }
    }

    /// The strokes for a character on macOS's layout: nil without a table from the helper (type for U.S.), empty
    /// if the layout has no key for it.
    static func strokes(for c: Character) -> [Stroke]? {
        refresh()
        if table.isEmpty { return nil }
        return table[c] ?? []
    }

    static func send(_ strokes: [Stroke]) {
        for k in strokes {
            if k.shift { henge_vm_key_hid(0xE1, 1) }
            if k.option { henge_vm_key_hid(0xE2, 1) }
            henge_vm_key_hid(k.usage, 1)
            henge_vm_key_hid(k.usage, 0)
            if k.option { henge_vm_key_hid(0xE2, 0) }
            if k.shift { henge_vm_key_hid(0xE1, 0) }
        }
    }

    private static func refresh() {
        var now = seq
        let text = henge_share_copy_keymap(&now)
        seq = now
        guard let text else { return }
        defer { free(text) }
        let table = String(cString: text)
        parse(table)
        if let savedFile { try? table.write(to: savedFile, atomically: true, encoding: .utf8) }
    }

    /// The helper's table (tools/henge-agent.m, keymapText): "layout\t<ID>\t<ANSI|ISO|JIS>", then
    /// "<char>\t<vk> <mods>[ <vk> <mods>]" per character.
    static func parse(_ text: String) {
        var new: [Character: [Stroke]] = [:]
        var iso = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count >= 2 else { continue }
            if parts[0] == "layout" {
                layoutID = String(parts[1])
                iso = parts.count > 2 && parts[2] == "ISO"
                continue
            }
            guard parts[0].count == 1, let c = parts[0].first else { continue }
            let numbers = parts[1].split(separator: " ").compactMap { Int($0) }
            guard !numbers.isEmpty, numbers.count % 2 == 0 else { continue }
            var strokes: [Stroke] = []
            for i in stride(from: 0, to: numbers.count, by: 2) {
                guard let usage = hid(forMacKey: numbers[i], iso: iso) else { strokes = []; break }
                strokes.append(Stroke(usage: usage, shift: numbers[i + 1] & 1 != 0, option: numbers[i + 1] & 2 != 0))
            }
            if !strokes.isEmpty { new[c] = strokes }
        }
        table = new
        HengeLog.log("keyboard", "macOS layout \(layoutID)\(iso ? " (ISO)" : ""): \(new.count) characters")
    }

    /// The USB key for a Mac virtual key code (kVK_ANSI_*), as macOS maps them back. On an ISO keyboard macOS swaps
    /// the key left of 1 and the one beside the left Shift.
    static func hid(forMacKey vk: Int, iso: Bool) -> UInt8? {
        if vk == 10 { return iso ? 0x35 : 0x64 }
        if vk == 50 { return iso ? 0x64 : 0x35 }
        guard vk >= 0, vk < macToHID.count, macToHID[vk] != 0 else { return nil }
        return macToHID[vk]
    }

    /// kVK_ANSI_A (0) … kVK_ANSI_Grave (50); 0 where a code is not a typing key here.
    private static let macToHID: [UInt8] = [
        0x04, 0x16, 0x07, 0x09, 0x0B, 0x0A, 0x1D, 0x1B, 0x06, 0x19, // A S D F H G Z X C V
        0x64, 0x05, 0x14, 0x1A, 0x08, 0x15, 0x1C, 0x17, 0x1E, 0x1F, // § B Q W E R Y T 1 2
        0x20, 0x21, 0x23, 0x22, 0x2E, 0x26, 0x24, 0x2D, 0x25, 0x27, // 3 4 6 5 = 9 7 - 8 0
        0x30, 0x12, 0x18, 0x2F, 0x0C, 0x13, 0x28, 0x0F, 0x0D, 0x34, // ] O U [ I P Return L J '
        0x0E, 0x33, 0x31, 0x36, 0x38, 0x11, 0x10, 0x37, 0x2B, 0x2C, // K ; \ , / N M . Tab Space
        0x35,                                                       // `
    ]
}
