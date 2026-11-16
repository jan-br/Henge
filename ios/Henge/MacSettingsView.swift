import SwiftUI

/// One Mac: what it has, and what can be done with it.
struct MacSettingsView: View {
    @ObservedObject private var machines = Machines.shared
    @Environment(\.dismiss) private var dismiss
    @State private var mac: VirtualMac
    @State private var confirmDelete = false
    @State private var movingExport = false
    @AppStorage("henge.cpus") private var cpus = 4
    @State private var customWidthText = ""
    @State private var customHeightText = ""

    init(mac: VirtualMac) { _mac = State(initialValue: mac) }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                DeskHeading("Name")
                TextField("Name", text: $mac.name)
                    .font(.system(size: 16))
                    .submitLabel(.done)
                    .padding(.horizontal, 17)
                    .padding(.vertical, 14)
                    .deskCard()
                    .onSubmit(save)

                DeskHeading("Memory")
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("\(mac.ramMB / 1024) GB").font(.system(size: 26, weight: .bold))
                        Spacer()
                        Text(Entitlements.increasedMemory ? "Outside the app's limit once JIT is on" : "Used from free storage if needed")
                            .font(.system(size: 13)).foregroundStyle(Desk.dim).multilineTextAlignment(.trailing)
                    }
                    Stepper("Memory", value: Binding(get: { mac.ramMB / 1024 }, set: { mac.ramMB = $0 * 1024; save() }), in: Device.memoryChoices)
                        .font(.system(size: 16))
                    if let note = Device.memoryNote(mac.ramMB / 1024) {
                        Text(note).font(.system(size: 13)).foregroundStyle(Desk.dim)
                    }
                }
                .padding(17)
                .deskCard()

                DeskHeading("Processors")
                Stepper(value: $cpus, in: 1...6) {
                    HStack {
                        Text("CPUs").font(.system(size: 16))
                        Spacer()
                        Text("\(cpus)").font(.system(size: 16, weight: .semibold))
                    }
                }
                .padding(.horizontal, 17)
                .padding(.vertical, 10)
                .deskCard()

                DeskHeading("About This Mac")
                VStack(alignment: .leading, spacing: 12) {
                    Toggle(isOn: Binding(get: { mac.reportHostIdentity ?? false }, set: {
                        mac.reportHostIdentity = $0
                        if !$0 { mac.reportHostModelID = false }
                        save()
                    })) {
                        Text("Report this \(Device.name)").font(.system(size: 16))
                    }
                    Text("The Mac says it is \(Device.marketingName)\(Device.chipName.map { " with the \($0) chip" } ?? ""). Changes apply the next time this Mac starts.")
                        .font(.system(size: 13)).foregroundStyle(Desk.dim)
                    if mac.reportHostIdentity == true {
                        Toggle(isOn: Binding(get: { mac.reportHostModelID ?? false }, set: { mac.reportHostModelID = $0; save() })) {
                            Text("Also report a model identifier").font(.system(size: 16))
                        }
                        Text("Reports \(Device.snappedModelIdentifier(forOS: mac.osName)) so this Mac shows a matching icon; the name stays \(Device.marketingName). Snaps to the newest \(Device.name) this macOS recognises. Experimental: macOS keys some hardware decisions off the model.")
                            .font(.system(size: 13)).foregroundStyle(Desk.dim)
                    }
                }
                .padding(17)
                .deskCard()

                DeskHeading("Screen")
                screen

                DeskHeading("Storage")
                VStack(spacing: 11) {
                    HStack {
                        Text("\(ByteText.string(UInt64(max(mac.bytesUsed, 0)))) used").font(.system(size: 16))
                        Spacer()
                        Text("of \(ByteText.string(UInt64(max(mac.diskBytes, 0))))").font(.system(size: 16)).foregroundStyle(Desk.dim)
                    }
                    DeskBar(fraction: Double(mac.bytesUsed) / Double(max(mac.diskBytes, 1)))
                }
                .padding(17)
                .deskCard()

                DeskHeading("Manage")
                manage
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
            .deskColumn()
        }
        .background(Desk.page)
        .navigationTitle(mac.name)
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear(perform: save)
        .fileMover(isPresented: $movingExport, file: machines.lastExport) { result in
            switch result {
            case .success: machines.lastExport = nil
            case .failure(let error): machines.lastError = error.localizedDescription
            }
        }
        .confirmationDialog("Delete \(mac.name)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                machines.delete(mac.id)
                dismiss()
            }
        } message: {
            Text("Its disk is removed from this \(Device.name).")
        }
    }

    private var manage: some View {
        VStack(spacing: 0) {
            if let name = machines.exporting {
                VStack(alignment: .leading, spacing: 9) {
                    Text("Exporting \(name)… keep Henge open").font(.system(size: 15))
                    DeskBar(fraction: machines.exported)
                }
                .padding(17)
            } else {
                row("Export", symbol: "square.and.arrow.up", tint: Desk.accentLight) { machines.export(mac) }
            }
            if let folder = machines.lastExport {
                divider
                VStack(alignment: .leading, spacing: 8) {
                    Text("Saved in Files, under Henge, Exports, \(folder.lastPathComponent). Deleting Henge deletes it too, so move it somewhere else first.")
                        .font(.system(size: 13)).foregroundStyle(Desk.dim)
                    Button("Move Out of Henge…") { movingExport = true }
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(Desk.accentLight)
                }
                .padding(17)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            divider
            row("Delete this Mac", symbol: nil, tint: Desk.bad) { confirmDelete = true }
        }
        .deskCard()
    }

    private var divider: some View { Rectangle().fill(Desk.hairline).frame(height: 0.5) }

    private func row(_ title: String, symbol: String?, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).font(.system(size: 16)).foregroundStyle(tint)
                Spacer()
                if let symbol { Image(systemName: symbol).foregroundStyle(tint) }
            }
            .padding(.horizontal, 17)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
    }

    /// The Mac's screen: what it looks like (the fit, smaller sizes in the same shape, 16:9 or any size), whether it
    /// renders at 2x, and on an iPhone Duo unfolded, whether it fills the screen.
    private var screen: some View {
        let fit = Device.fitting(for: mac)
        let presets = Device.presets(for: fit)
        let fitIsWide = fit == (width: 1920, height: 1080)
        var choices = presets.map(\.choice) + ["fit", "custom"]
        if !fitIsWide { choices.append("wide") }
        if Device.isPad { choices += ["retina", "performance"] }
        // An older "w1280" shows as the scale it is.
        let stored = Device.scalePercent(of: mac.effectiveScreenChoice).map { "s\($0)" } ?? mac.effectiveScreenChoice
        let current = choices.contains(stored) ? stored : "fit"
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Scale").font(.system(size: 16))
                Spacer()
                Picker("Scale", selection: Binding(get: { current }, set: { setScreenChoice($0) })) {
                    Text("100% (fits this \(Device.name))").tag("fit")
                    ForEach(presets, id: \.choice) { p in Text("\(p.percent)%").tag(p.choice) }
                    if !fitIsWide { Text("1920 × 1080 (16:9)").tag("wide") }
                    if Device.isPad {
                        Text("Retina").tag("retina")
                        Text("Performance").tag("performance")
                    }
                    Text("Custom…").tag("custom")
                }
                .pickerStyle(.menu)
            }
            if current == "custom" {
                HStack(spacing: 8) {
                    TextField("Width", text: $customWidthText).keyboardType(.numberPad).textFieldStyle(.roundedBorder)
                    Text("×").foregroundStyle(Desk.dim)
                    TextField("Height", text: $customHeightText).keyboardType(.numberPad).textFieldStyle(.roundedBorder)
                    Button("Set", action: applyCustom).buttonStyle(.borderedProminent)
                }
                Text("Any size from 480 × 320 to \((mac.sharp ?? false) ? "1920 × 1440" : "3840 × 2880"), in steps of 8.")
                    .font(.system(size: 13)).foregroundStyle(Desk.dim)
            }
            if !mac.isPadRetina {
                Toggle("Sharp (HiDPI)", isOn: Binding(get: { mac.sharp ?? false }, set: {
                    mac.sharp = $0
                    mac.applyScreen()
                    syncCustomFields()
                    save()
                })).font(.system(size: 16))
                Text("Renders twice as many pixels each way so macOS draws at 2x: sharper, but about four times the work for the virtual GPU.")
                    .font(.system(size: 13)).foregroundStyle(Desk.dim)
            }
            if Device.largeScreen {
                Toggle("Fill the whole screen", isOn: Binding(get: { mac.fillScreen ?? true }, set: { fill in
                    mac.fillScreen = fill
                    mac.applyScreen()
                    save()
                })).font(.system(size: 16))
                Text("Off leaves a strip at the right for the time, battery and Wi-Fi, with Henge's controls under them.")
                    .font(.system(size: 13)).foregroundStyle(Desk.dim)
            }
            Text("Looks like \(Device.looksLike(for: mac).width) × \(Device.looksLike(for: mac).height)\((mac.sharp ?? false) ? ", renders \(mac.screen.width) × \(mac.screen.height)" : "") here. A scale is of the screen this Mac starts on, so it keeps its shape on either screen and either way up. For a larger UI, choose a smaller scale here rather than a scaled resolution in macOS's Displays settings: macOS's own scaling puts the pointer off where it clicks. Changes apply the next time this Mac starts\(InstantResume.hasSave(for: mac) ? "; its saved session will not be resumed" : "").")
                .font(.system(size: 13)).foregroundStyle(Desk.dim)
        }
        .padding(17)
        .deskCard()
        // A Mac fitted to another screen (an iPhone Duo's other one) shows the size it will start with.
        .onAppear {
            mac = machines.fittedForStart(mac)
            syncCustomFields()
        }
    }

    private func setScreenChoice(_ choice: String) {
        if choice == "custom", mac.customWidth == nil {
            let now = Device.looksLike(for: mac) // start from what it looks like now
            (mac.customWidth, mac.customHeight) = (now.width, now.height)
        }
        mac.retina = choice == "retina"
        mac.screenChoice = choice
        mac.applyScreen()
        syncCustomFields()
        save()
    }

    private func applyCustom() {
        guard let w = Int(customWidthText), let h = Int(customHeightText) else { syncCustomFields(); return }
        let s = Device.clampCustom(w, h, sharp: mac.sharp ?? false)
        (mac.customWidth, mac.customHeight) = (s.width, s.height)
        mac.screenChoice = "custom"
        mac.applyScreen()
        syncCustomFields()
        save()
    }

    /// The custom fields show the size a custom screen looks like (clamped, as it will be used).
    private func syncCustomFields() {
        let fit = Device.fitting(for: mac)
        let s = Device.clampCustom(mac.customWidth ?? fit.width, mac.customHeight ?? fit.height, sharp: mac.sharp ?? false)
        (customWidthText, customHeightText) = ("\(s.width)", "\(s.height)")
    }

    private func save() {
        if mac.name.isEmpty { mac.name = "Mac" }
        machines.update(mac)
    }
}
