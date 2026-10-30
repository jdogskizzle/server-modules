import SwiftUI

/// Type, version (or jar), Java and memory: shared by "change version" and "add server".
struct MCVersionFields: View {
    let client: APIClient
    @Binding var type: String
    @Binding var version: String
    @Binding var jar: String
    @Binding var java: String
    @Binding var memory: String
    /// Where to look for jar files: a server name or an import folder path.
    let jarFolder: String?

    @State private var versions: [String] = []
    @State private var jars: [String] = []

    var body: some View {
        Section {
            Picker("Type", selection: $type) {
                ForEach(MC.types, id: \.self) { Text(MC.typeLabel($0)).tag($0) }
            }
            if type == "CUSTOM" {
                if jars.isEmpty {
                    Text(jarFolder == nil ? "Choose a folder to copy from first." : "No .jar files in the server folder.")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Jar", selection: $jar) {
                        Text("Choose").tag("")
                        ForEach(jars, id: \.self) { Text($0).tag($0) }
                    }
                }
            } else {
                HStack {
                    TextField("Version, e.g. 1.21.4 or LATEST", text: $version)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if !versions.isEmpty {
                        Menu {
                            ForEach(versions, id: \.self) { v in Button(v) { version = v } }
                        } label: {
                            Image(systemName: "list.bullet")
                        }
                    }
                }
            }
            Picker("Java", selection: $java) {
                ForEach(MC.javas, id: \.self) { Text(MC.javaLabel($0)).tag($0) }
            }
            TextField("Memory, e.g. 4G or 1536M", text: $memory)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
        } header: {
            Text("Server")
        } footer: {
            Text("Java 25 for 26.x, Java 21 for 1.20.5 – 1.21.x, older Java for older versions.")
        }
        .task(id: type) {
            guard type != "CUSTOM" else { versions = []; return }
            versions = (try? await client.get("api/versions/\(type.lowercased())", as: [String].self)) ?? []
        }
        .task(id: "\(type)|\(jarFolder ?? "")") {
            guard type == "CUSTOM", let jarFolder else { jars = []; return }
            jars = (try? await client.get("api/jars", query: [URLQueryItem(name: "folder", value: jarFolder)], as: [String].self)) ?? []
        }
    }

    /// The version part of a request body.
    static func requestBody(type: String, version: String, jar: String, java: String, memory: String) -> JSONObject {
        var b: JSONObject = ["type": .string(type), "java": .string(java),
                             "memory": .string(memory.trimmingCharacters(in: .whitespaces).uppercased())]
        if type == "CUSTOM" { b["jar"] = .string(jar) } else { b["version"] = .string(version.trimmingCharacters(in: .whitespaces)) }
        return b
    }
}

struct MCVersionView: View {
    let store: MCPanelStore
    let server: MCServer
    @Environment(\.dismiss) private var dismiss
    @State private var type = "PAPER"
    @State private var version = ""
    @State private var jar = ""
    @State private var java = "java25"
    @State private var memory = "4G"
    @State private var loaded = false
    @State private var working = false
    @State private var error: String?

    var body: some View {
        Form {
            MCVersionFields(client: store.client, type: $type, version: $version, jar: $jar, java: $java,
                            memory: $memory, jarFolder: server.name)
            Section {
                Text(server.status.isUp
                     ? "The server is backed up, then restarted with the new settings. If they don't start, the old settings come back."
                     : "The new settings are used the next time the server starts.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let error { Section { Text(error).foregroundStyle(.red) } }
        }
        .navigationTitle("Change \(server.name)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Apply") { Task { await submit() } }
                    .disabled(working || (type == "CUSTOM" ? jar.isEmpty : version.trimmingCharacters(in: .whitespaces).isEmpty))
            }
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            let c = server.config
            type = c.type ?? "PAPER"
            version = c.version?.string ?? ""
            jar = c.jar ?? ""
            java = c.java ?? "java25"
            memory = c.memory?.string ?? "4G"
        }
    }

    private func submit() async {
        working = true
        defer { working = false }
        let payload = MCVersionFields.requestBody(type: type, version: version, jar: jar, java: java, memory: memory)
        do {
            let _: MCJob = try await store.client.fetch("POST", "api/servers/\(APIClient.segment(server.name))/version", body: .object(payload))
            store.notice = "Changing \(server.name). Follow it under Recent tasks."
            await store.refresh()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct MCAddServerView: View {
    let store: MCPanelStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var port = ""
    @State private var type = "PAPER"
    @State private var version = "LATEST"
    @State private var jar = ""
    @State private var java = "java25"
    @State private var memory = "4G"
    @State private var autopause = true
    @State private var autostart = true
    @State private var importFrom = ""
    @State private var difficulty = ""
    @State private var gamemode = ""
    @State private var seed = ""
    @State private var imports: [String] = []
    @State private var forwardTo: String?
    @State private var working = false
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                TextField("Name (lowercase, e.g. survival)", text: $name)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Port", text: $port)
                    .keyboardType(.numberPad)
            } footer: {
                Text("Forward this TCP port to \(forwardTo.flatMap { $0.isEmpty ? nil : $0 } ?? "this machine") on your router for players outside your network.")
            }
            if !imports.isEmpty {
                Section {
                    Picker("Start from", selection: $importFrom) {
                        Text("A new world").tag("")
                        ForEach(imports, id: \.self) { p in
                            Text((p as NSString).lastPathComponent).tag(p)
                        }
                    }
                } footer: {
                    Text("Copy an existing server folder (world, settings and mods), or start fresh.")
                }
            }
            MCVersionFields(client: store.client, type: $type, version: $version, jar: $jar, java: $java,
                            memory: $memory, jarFolder: importFrom.isEmpty ? nil : importFrom)
            Section("World") {
                Picker("Difficulty", selection: $difficulty) {
                    Text(importFrom.isEmpty ? "Default" : "Keep").tag("")
                    ForEach(MC.difficulties, id: \.self) { Text(Format.capitalized($0)).tag($0) }
                }
                Picker("Game mode", selection: $gamemode) {
                    Text(importFrom.isEmpty ? "Default" : "Keep").tag("")
                    ForEach(MC.gamemodes, id: \.self) { Text(Format.capitalized($0)).tag($0) }
                }
                if importFrom.isEmpty {
                    TextField("Seed (blank = random)", text: $seed)
                        .autocorrectionDisabled()
                }
            }
            Section {
                Toggle("Pause when empty", isOn: $autopause)
                Toggle("Start at boot", isOn: $autostart)
            } footer: {
                Text("A paused server sleeps 5 minutes after the last player leaves and wakes when someone joins.")
            }
            if let error { Section { Text(error).foregroundStyle(.red) } }
        }
        .navigationTitle("Add server")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Add") { Task { await submit() } }
                    .disabled(working || name.isEmpty || Int(port) == nil)
            }
        }
        .task {
            imports = (try? await store.client.get("api/imports", as: [String].self)) ?? []
            forwardTo = (try? await store.client.get("api/config", as: MCPanelConfig.self))?.forwardTo
            if port.isEmpty {
                let used = (store.servers?.servers ?? []).compactMap(\.config.port)
                port = String((used.max() ?? 25564) + 1)
            }
        }
    }

    private func submit() async {
        guard let p = Int(port) else { return }
        working = true
        defer { working = false }
        var payload = MCVersionFields.requestBody(type: type, version: version, jar: jar, java: java, memory: memory)
        payload["name"] = .string(name.trimmingCharacters(in: .whitespaces).lowercased())
        payload["port"] = .number(Double(p))
        payload["autopause"] = .bool(autopause)
        payload["autostart"] = .bool(autostart)
        payload["import_from"] = importFrom.isEmpty ? .null : .string(importFrom)
        payload["difficulty"] = difficulty.isEmpty ? .null : .string(difficulty)
        payload["gamemode"] = gamemode.isEmpty ? .null : .string(gamemode)
        payload["seed"] = .string(seed)
        do {
            let _: MCJob = try await store.client.fetch("POST", "api/servers", body: .object(payload))
            store.notice = "Adding \(name). Follow it under Tasks."
            await store.refresh()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
