import SwiftUI
import GridCore

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var draft: Configuration
    @State private var selectedGrid = 0
    @State private var json = ""
    @State private var localError = ""
    init(model: AppModel) { self.model = model; _draft = State(initialValue: model.configuration) }
    var body: some View {
        VStack(spacing: 12) {
            TabView {
                setup.tabItem { Text("Setup") }
                grids.tabItem { Text("Grids & layouts") }
                gestures.tabItem { Text("Gestures") }
                advanced.tabItem { Text("Import & diagnostics") }
            }
            HStack {
                Text(localError.isEmpty ? model.message : localError).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                Button("Revert") { draft = model.configuration; localError = "" }
                Button("Save settings") {
                    do { try draft.validate(); model.apply(draft); localError = "" }
                    catch { localError = error.localizedDescription }
                }.keyboardShortcut("s", modifiers: .command)
            }.padding(.horizontal)
        }.padding(16).frame(width: 820, height: 680)
            .onChange(of: model.configuration) { draft = model.configuration }
    }
    private var setup: some View {
        Form {
            Text("AeroGrid organiza tus ventanas en espacios. Usá el panel superior para moverlas y los gestos para navegar.")
            LabeledContent("AeroGrid", value: model.paused ? "En pausa" : (model.backendReady ? "Activo" : "Requiere atención"))
            LabeledContent("Gesture input", value: model.paused ? "En pausa" : (model.inputReady ? "Listening" : "Permission required"))
            HStack {
                Button("Grant Accessibility") { model.requestPermission() }
                Button("Recover") { model.recover() }
            }
            Button(model.paused ? "Reanudar AeroGrid" : "Pausar AeroGrid") { model.setPaused(!model.paused) }.disabled(model.pauseChanging)
            Divider()
            Text("macOS may also respond to 3- and 4-finger swipes. In Trackpad → More Gestures, disable or remap Swipe between full-screen applications, Mission Control, and App Exposé for the finger counts you use here. If three-finger dragging is enabled, turn it off in Accessibility → Pointer Control. AeroGrid does not change these settings for you.")
            Button("Open Trackpad settings") { model.openTrackpadSettings() }
            Picker("Display being used", selection: $draft.targeting) {
                Text("Pointer at swipe start").tag(Targeting.pointer)
                Text("Focused application at swipe start").tag(Targeting.focused)
            }
            Toggle("Start AeroGrid at login", isOn: Binding(get: { model.loginEnabled }, set: model.setLogin))
            Text("AeroGrid inicia y controla automáticamente el servicio de ventanas.").font(.caption).foregroundStyle(.secondary)
            Text("Display roles").font(.headline)
            ForEach(Array(Set(draft.grids.map(\.displayRole))).sorted(), id: \.self) { role in
                Picker(role, selection: Binding(get: { draft.displayAssignments[role] ?? "" }, set: { draft.displayAssignments[role] = $0.isEmpty ? nil : $0 })) {
                    Text("Automatic (one matching display)").tag("")
                    ForEach(model.desktop?.displays ?? [], id: \.id) { Text($0.name).tag($0.id) }
                }
            }
        }.formStyle(.grouped)
    }
    private var grids: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Un mapa que crece con tus ventanas", systemImage: "square.grid.3x3") .font(.title2)
            Text("Organizá ventanas y espacios desde el panel superior. Arrastrá una tarjeta para mover una ventana, o el encabezado para mover el casillero completo. Los espacios vacíos que creás también se pueden visitar con gestos.")
            Text("Al desconectar, los bloques lado a lado se separan en casilleros vecinos. Las pilas se conservan. Al reconectar, se reúnen los grupos que no reorganizaste manualmente.")
            Button("Abrir organizador") { model.showOverview?() }
            Spacer()
        }.padding(24)
    }
    private var gestures: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Test gestures without switching", isOn: $model.testingGestures)
                Text(model.gestureMessage).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                HStack { Text("Swipe threshold"); Slider(value: $draft.threshold, in: 0.02...0.15); Text(String(format: "%.3f", draft.threshold)) }
                Toggle("Invert swipe directions", isOn: $draft.invert)
                ForEach(draft.bindings.indices, id: \.self) { i in
                    HStack {
                        Picker("Fingers", selection: $draft.bindings[i].fingers) { Text("3").tag(3); Text("4").tag(4) }.frame(width: 90)
                        Picker("Modifier", selection: $draft.bindings[i].modifiers) { Text("None").tag(0); Text("Option").tag(4); Text("Shift").tag(1); Text("Control").tag(2); Text("Command").tag(8) }.frame(width: 130)
                        Picker("Direction", selection: $draft.bindings[i].direction) { ForEach(Direction.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.frame(width: 110)
                        Picker("Action", selection: $draft.bindings[i].action) {
                            ForEach(["navigate","next-grid","previous-grid","next-window","previous-window","overview"], id: \.self) { Text($0).tag($0) }
                        }
                        Picker("Scope", selection: $draft.bindings[i].scope) { Text("This display").tag(Scope.active); Text("All displays").tag(Scope.all) }.frame(width: 150)
                        Button("−") { draft.bindings.remove(at: i) }
                    }.labelsHidden()
                }
                Button("Add binding") { draft.bindings.append(GestureBinding(fingers: 4, modifiers: 4, direction: .up, action: "overview")) }
                Text("One switch per swipe. Targets and modifiers are captured when fingers touch down. Diagonal swipes are ignored until a clear axis emerges.").font(.caption).foregroundStyle(.secondary)
            }.padding()
        }
    }
    private var advanced: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button("Export configuration") { model.exportConfig() }
                Button("Import configuration") { model.importConfig() }
                Button("Open local files") { NSWorkspace.shared.open(model.directory) }
            }
            TextField("AeroSpace CLI", text: $draft.backendPath)
            Text("Advanced input configuration. Organize the dynamic map from the organizer; legacy grid definitions are preserved for recovery.").font(.caption)
            HStack {
                Button("Load draft as JSON") { let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; json = String(decoding: (try? e.encode(draft)) ?? Data(), as: UTF8.self) }
                Button("Read JSON into draft") {
                    do { let c = try JSONDecoder().decode(Configuration.self, from: Data(json.utf8)); try c.validate(); draft = c; localError = "" }
                    catch { localError = error.localizedDescription }
                }
            }
            TextEditor(text: $json).font(.system(.caption, design: .monospaced)).border(Color.gray.opacity(0.3))
        }.padding()
    }
}
