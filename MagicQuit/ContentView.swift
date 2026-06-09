import SwiftUI
import AppKit
import Combine
import LaunchAtLogin
import os.log
import ScriptingBridge
import UniformTypeIdentifiers

enum Preferences {
    static let legacyHoursUntilCloseKey = "hoursUntilClose"
    static let minutesUntilCloseKey = "minutesUntilClose"
    static let defaultMinutesUntilClose = 8 * 60
    static let maximumMinutesUntilClose = 72 * 60

    static func migrateIdleTimePreferenceIfNeeded(userDefaults: UserDefaults = .standard) {
        guard userDefaults.object(forKey: minutesUntilCloseKey) == nil else { return }
        guard let legacyHours = userDefaults.object(forKey: legacyHoursUntilCloseKey) as? Int else { return }

        let migratedMinutes = min(max(legacyHours * 60, 1), maximumMinutesUntilClose)
        userDefaults.set(migratedMinutes, forKey: minutesUntilCloseKey)
    }

    static func formattedIdleTime(minutes: Int) -> String {
        let clampedMinutes = min(max(minutes, 1), maximumMinutesUntilClose)
        let hours = clampedMinutes / 60
        let remainingMinutes = clampedMinutes % 60

        if hours == 0 {
            return "\(remainingMinutes)m"
        }

        if remainingMinutes == 0 {
            return "\(hours)h"
        }

        return "\(hours)h \(remainingMinutes)m"
    }
}

struct ExcludedApp: Codable, Hashable, Identifiable {
    let bundleIdentifier: String
    let name: String
    let path: String

    var id: String {
        bundleIdentifier
    }

    var icon: NSImage {
        NSWorkspace.shared.icon(forFile: path)
    }

    init(bundleIdentifier: String, name: String, path: String) {
        self.bundleIdentifier = bundleIdentifier
        self.name = name
        self.path = path
    }

    init?(url: URL) {
        guard url.pathExtension.lowercased() == "app",
              let bundle = Bundle(url: url),
              let bundleIdentifier = bundle.bundleIdentifier else {
            return nil
        }

        let displayName = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
        let bundleName = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
        let fileName = url.deletingPathExtension().lastPathComponent

        self.bundleIdentifier = bundleIdentifier
        self.name = displayName ?? bundleName ?? fileName
        self.path = url.path
    }
}

class RunningAppsManager: ObservableObject {
    @Published var runningApps: [NSRunningApplication: Date] = [:]
    @Published var appsToClose: [String] = []
    private var timer: Timer?
    private var lastOpenAppsCheck = Date.distantPast
    @AppStorage(Preferences.minutesUntilCloseKey) var minutesUntilClose: Int = Preferences.defaultMinutesUntilClose
    @Published var toggleStatus: [String: Bool] = [:] {
        willSet {
            objectWillChange.send()
        }
    }
    @Published var excludedApps: [ExcludedApp] = []
    @AppStorage("com.MagicQuit.toggleStatus") var toggleStatusData: Data = Data()
    @AppStorage("com.MagicQuit.excludedApps") var excludedAppsData: Data = Data()
    
    let log = OSLog(subsystem: Bundle.main.bundleIdentifier!, category: "RunningAppsManager")
    
    init() {
        Preferences.migrateIdleTimePreferenceIfNeeded()
        syncToggleStatus()
        syncExcludedApps()
        addCurrentRunningApps()
        
        os_log("Init", log: log, type: .debug)
        let didDeactivateObserver = NSWorkspace.shared.notificationCenter
        didDeactivateObserver.addObserver(forName: NSWorkspace.didDeactivateApplicationNotification,
                                          object: nil, // always NSWorkspace
                                          queue: OperationQueue.main) { (notification: Notification) in
            if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                os_log("didDeactivate: %{public}@", log: self.log, type: .debug, app.localizedName ?? "Unknown")
                if !self.isBlockedApp(app) {
                    DispatchQueue.main.async {
                        self.runningApps[app] = Date()
                    }
                }
            }
        }
        // Setup Timer
        self.timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            // Iterate over the app's windows and check if any of them are key or main
            let now = Date()
            let appWindowIsActive = NSApplication.shared.windows.contains(where: { $0.isKeyWindow || $0.isMainWindow })
            if appWindowIsActive || now.timeIntervalSince(self.lastOpenAppsCheck) >= 5 {
                self.lastOpenAppsCheck = now
                self.checkOpenApps()
            }
        }
    }
    
    deinit {
        os_log("RunningAppsManager is being deallocated", log: log, type: .debug)
    }
    
    // Synchronize toggleStatus with toggleStatusData
    private func syncToggleStatus() {
        if let status = try? JSONDecoder().decode([String: Bool].self, from: toggleStatusData) {
            toggleStatus = status
        }
    }
    
    // Save toggleStatus to toggleStatusData
    func saveToggleStatus() {
        if let data = try? JSONEncoder().encode(toggleStatus) {
            toggleStatusData = data
        }
    }

    private func syncExcludedApps() {
        if let apps = try? JSONDecoder().decode([ExcludedApp].self, from: excludedAppsData) {
            excludedApps = apps.sorted(by: { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending })
        }
    }

    private func saveExcludedApps() {
        let sortedApps = excludedApps.sorted(by: { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending })
        excludedApps = sortedApps

        if let data = try? JSONEncoder().encode(sortedApps) {
            excludedAppsData = data
        }
    }

    @discardableResult
    func addExcludedApp(from url: URL) -> ExcludedApp? {
        guard let appToExclude = ExcludedApp(url: url) else {
            return nil
        }

        if let existingIndex = excludedApps.firstIndex(where: { $0.bundleIdentifier == appToExclude.bundleIdentifier }) {
            excludedApps[existingIndex] = appToExclude
        } else {
            excludedApps.append(appToExclude)
        }

        removeExcludedAppsFromRunningList()
        saveExcludedApps()
        return appToExclude
    }

    func removeExcludedApp(bundleIdentifier: String) {
        excludedApps.removeAll { $0.bundleIdentifier == bundleIdentifier }
        saveExcludedApps()
        addCurrentRunningApps()
    }

    private func removeExcludedAppsFromRunningList() {
        let userExcludedIdentifiers = Set(excludedApps.map(\.bundleIdentifier))
        for app in runningApps.keys {
            guard let bundleIdentifier = app.bundleIdentifier else { continue }
            if userExcludedIdentifiers.contains(bundleIdentifier) {
                runningApps[app] = nil
            }
        }
    }
    
    private func isBlockedApp(_ app: NSRunningApplication) -> Bool {
        let currentAppBundleIdentifier = Bundle.main.bundleIdentifier
        let userExcludedIdentifiers = Set(excludedApps.map(\.bundleIdentifier))
        let excludedIdentifiers = ["com.apple.loginwindow",
                                   "com.apple.systemuiserver",
                                   "com.apple.dock",
                                   "com.apple.finder",
                                   "com.apple.coreautha",
                                   "com.apple.Spotlight",
                                   "com.apple.notificationcenterui",
                                   "com.apple.Siri"
        ]
        if app.activationPolicy == .regular,
           app.bundleIdentifier != currentAppBundleIdentifier,
           !excludedIdentifiers.contains(app.bundleIdentifier ?? ""),
           !userExcludedIdentifiers.contains(app.bundleIdentifier ?? "") {
            return false
        }
        return true
    }
    
    private func addCurrentRunningApps() {
        let workspace = NSWorkspace.shared
        let apps = workspace.runningApplications
        let currentDate = Date()
        
        // Add new apps to runningApps
        for app in apps {
            if !isBlockedApp(app), self.runningApps[app] == nil {
                DispatchQueue.main.async {
                    self.runningApps[app] = currentDate
                }
            }
        }
    }
    
    
    private func checkOpenApps() {
        os_log("checkOpenApps", log: log, type: .debug)
        let workspace = NSWorkspace.shared
        let apps = workspace.runningApplications
        let currentDate = Date()
        
        // Remove apps from runningApps that are not active anymore
        let currentApps = apps.compactMap { $0 }
        runningApps = runningApps.filter { currentApps.contains($0.key) }
        
        // Remove apps that are blocked (e.g. only appear in Menu Bar) from runningApps
        for app in runningApps.keys {
            if isBlockedApp(app) {
                runningApps[app] = nil
            }
        }
        
        // Set date of the currently active app to currentDate
        if let activeApp = workspace.frontmostApplication, !isBlockedApp(activeApp) {
            runningApps[activeApp] = currentDate
        }
        
        addCurrentRunningApps()
        
        // Check if any apps have been running for more than minutesUntilClose and terminate them
        let secondsUntilClose = max(minutesUntilClose, 1) * 60
        for (app, startDate) in runningApps {
            let elapsedTime = currentDate.timeIntervalSince(startDate)
            if elapsedTime > Double(secondsUntilClose), app.isFinishedLaunching, toggleStatus[app.localizedName ?? ""] ?? true {
                let isTerminated = app.terminate()
                if isTerminated {
                    runningApps[app] = nil
                }
            }
        }
    }
}

struct ContentView: View {
    static let toggleStatusKey = "com.MagicQuit.toggleStatus"
    enum HoveredButton: Hashable {
        case quit
        case settings
    }
    @State private var hoveredButton: HoveredButton? = nil
    @State private var showingSettings = false
    @State private var settingsWindowController: SettingsWindowController?
    @State private var selectedExclusionID: String?
    //@State private var toggleStatus: [String: Bool] = [:]
    //@AppStorage(ContentView.toggleStatusKey) private var toggleStatusData: Data = Data()
    @ObservedObject private var manager: RunningAppsManager
    
    init(manager: RunningAppsManager) {
        self.manager = manager
    }
    
    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                ForEach(Array(manager.runningApps).sorted(by: { $0.0.localizedName! < $1.0.localizedName! }), id: \.0) { app in
                    AppRow(app: app, manager: manager)
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 5)
            .padding(.bottom, 0)
            Divider()
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
            ExclusionSection(manager: manager, selectedExclusionID: $selectedExclusionID)
            Divider()
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
            Button(action: {
                if let currentSettingsWindowController = SettingsWindowController.current {
                    currentSettingsWindowController.window?.makeKeyAndOrderFront(nil)
                    NSApp.activate(ignoringOtherApps: true)
                } else {
                    settingsWindowController = SettingsWindowController(rootView: SettingsView())
                    NSApp.activate(ignoringOtherApps: true) // Activate the application
                    settingsWindowController?.showWindow(nil)
                }
            }) {
                HStack {
                    Text("Settings")
                        .frame(maxWidth: .infinity, alignment: .leading) // aligns text to the leading edge
                        .padding(.horizontal, 10) // adds padding to the leading edge of the text
                        .padding(.vertical, 5)
                        .foregroundColor(hoveredButton == .settings ? Color.white : Color.primary) // Change text color to white when hovering
                    
                }
                .frame(maxWidth: .infinity)
                //.padding(.vertical, 10) // adds vertical padding to the entire button
                .background(
                    Group {
                        if hoveredButton == .settings {
                            RoundedRectangle(cornerRadius: 5)
                                .fill(Color.blue)
                        } else {
                            RoundedRectangle(cornerRadius: 5)
                                .fill(Color.clear)
                        }
                    }
                )
                .onHover { hovering in
                    hoveredButton = hovering ? .settings : nil
                }
            }
            .contentShape(Rectangle())
            .buttonStyle(PlainButtonStyle())
            Button(action: {
                NSApplication.shared.terminate(self)
            }) {
                HStack {
                    Text("Quit MagicQuit")
                        .frame(maxWidth: .infinity, alignment: .leading) // aligns text to the leading edge
                        .padding(.horizontal, 10) // adds padding to the leading edge of the text
                        .padding(.vertical, 5)
                        .foregroundColor(hoveredButton == .quit ? Color.white : Color.primary) // Change text color to white when hovering
                    
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                //.padding(.vertical, 10) // adds vertical padding to the entire button
                .background(
                    Group {
                        if hoveredButton == .quit {
                            RoundedRectangle(cornerRadius: 5)
                                .fill(Color.blue)
                        } else {
                            RoundedRectangle(cornerRadius: 5)
                                .fill(Color.clear)
                        }
                    }
                )
                .onHover { hovering in
                    hoveredButton = hovering ? .quit : nil
                }
            }.contentShape(Rectangle())
                .buttonStyle(PlainButtonStyle())
            
        }
        
        .frame(width: 320)
        .padding(5)
        
    }
}

struct ExclusionSection: View {
    @ObservedObject var manager: RunningAppsManager
    @Binding var selectedExclusionID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Exclusions")
                    .font(.headline)

                Spacer()

                Button(action: addExclusion) {
                    Image(systemName: "plus")
                }
                .buttonStyle(BorderlessButtonStyle())
                .help("Add an app to always exclude")

                Button(action: removeSelectedExclusion) {
                    Image(systemName: "minus")
                }
                .buttonStyle(BorderlessButtonStyle())
                .help("Remove selected exclusion")
                .disabled(selectedExclusionID == nil)
            }

            if manager.excludedApps.isEmpty {
                Text("No apps excluded")
                    .foregroundColor(.secondary)
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
            } else {
                VStack(spacing: 2) {
                    ForEach(manager.excludedApps) { excludedApp in
                        ExcludedAppRow(
                            app: excludedApp,
                            isSelected: selectedExclusionID == excludedApp.id
                        ) {
                            selectedExclusionID = excludedApp.id
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 2)
        .onChange(of: manager.excludedApps) { apps in
            if let selectedExclusionID,
               apps.contains(where: { $0.id == selectedExclusionID }) {
                return
            }
            selectedExclusionID = apps.first?.id
        }
    }

    private func addExclusion() {
        let panel = NSOpenPanel()
        panel.title = "Choose App to Exclude"
        panel.message = "Choose apps MagicQuit should always leave open."
        panel.prompt = "Exclude"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType.applicationBundle]

        NSApp.activate(ignoringOtherApps: true)

        if panel.runModal() == .OK {
            for url in panel.urls {
                if let excludedApp = manager.addExcludedApp(from: url) {
                    selectedExclusionID = excludedApp.id
                }
            }
        }
    }

    private func removeSelectedExclusion() {
        guard let selectedExclusionID else { return }
        manager.removeExcludedApp(bundleIdentifier: selectedExclusionID)
        self.selectedExclusionID = manager.excludedApps.first?.id
    }
}

struct ExcludedAppRow: View {
    let app: ExcludedApp
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(nsImage: app.icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 20, height: 20)

                Text(app.name)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer()
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
            .cornerRadius(5)
        }
        .buttonStyle(PlainButtonStyle())
    }
}

struct AppRow: View {
    var app: (key: NSRunningApplication, value: Date)
    @ObservedObject var manager: RunningAppsManager
    @AppStorage(Preferences.minutesUntilCloseKey) var minutesUntilClose: Int = Preferences.defaultMinutesUntilClose
    @AppStorage("showCloseButton") var showCloseButton: Bool = false
    
    var shouldQuitCheckbox: Binding<Bool> {
        Binding<Bool>(
            get: { manager.toggleStatus[app.key.localizedName ?? ""] ?? true },
            set: { newValue in
                manager.toggleStatus[app.key.localizedName ?? ""] = newValue
                manager.saveToggleStatus() // Save the status each time it changes
            }
        )
    }
    
    var body: some View {
        let secondsUntilClose = (minutesUntilClose * 60) - Int(Date().timeIntervalSince(app.value))
        let isLessThanHour = secondsUntilClose < 3600
        
        HStack {
            Toggle(isOn: shouldQuitCheckbox) {
                EmptyView() // Empty view as we don't want to show any label
            }
            .toggleStyle(CheckboxToggleStyle())
            .frame(alignment: .leading)
            
            let icon = NSWorkspace.shared.icon(forFile: app.key.bundleURL?.path ?? "")
            
            Image(nsImage: icon)
                .resizable()
                .scaledToFit()
                .frame(width: 28, height: 28)
            
            Text(app.key.localizedName ?? "Unknown")
                .frame(minWidth: 100, maxWidth: .infinity, alignment: .leading)
                .fontWeight(isLessThanHour && shouldQuitCheckbox.wrappedValue ? .bold : .regular)
                .lineLimit(1)  // Limit to one line
                .truncationMode(.tail)
                .foregroundColor(shouldQuitCheckbox.wrappedValue ? .primary : .gray) // Change the text color based on the toggle status
            
            Spacer() // Add a spacer to push apart the two Text views
            if shouldQuitCheckbox.wrappedValue {
                let secondsUntilClose = (minutesUntilClose * 60) - Int(Date().timeIntervalSince(app.value))
                Text(formatTime(seconds: secondsUntilClose)).frame(alignment: .trailing)
                    .fontWeight(isLessThanHour ? .bold : .regular)
                    .alignmentGuide(.trailing, computeValue: { dimension in
                        dimension[.trailing]
                    })
            }
            
            Button(action: {
                // Set date of the app to now
                manager.runningApps[app.0] = Date()
            }) {
                Image(systemName: "arrow.uturn.backward.circle") // Use SF Symbols for the star icon
            }
            .buttonStyle(PlainButtonStyle())
            .frame(alignment: .trailing)
            .disabled(!shouldQuitCheckbox.wrappedValue) // Disable the button if the checkbox is not checked
            if showCloseButton {
                Button(action: {
                    // Close the app
                    app.key.terminate()
                }) {
                    Image(systemName: "x.circle") // Use SF Symbols for the star icon
                }
                .buttonStyle(PlainButtonStyle())
                .frame(alignment: .trailing)
                .disabled(!shouldQuitCheckbox.wrappedValue) // Disable the button if the checkbox is not checked
            }
            
        }
        .frame(maxWidth: .infinity)
    }
    
    // your formatTime function here
    private func formatTime(seconds: Int) -> String {
        let remainingSeconds = max(seconds, 0)

        if remainingSeconds >= 3600 {
            let hours = remainingSeconds / 3600
            let minutes = (remainingSeconds % 3600) / 60
            if minutes > 0 {
                return "\(hours)h \(minutes)m left"
            }
            return "\(hours)h left"
        } else if remainingSeconds >= 60 {
            return "\(remainingSeconds / 60)m left"
        } else {
            return "\(remainingSeconds)s left"
        }
    }
}

class SettingsWindowController: NSWindowController {
    static var current: SettingsWindowController?
    
    convenience init(rootView: SettingsView) {
        let hostingController = NSHostingController(rootView: rootView.frame(width: 600, height: 400))
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Settings"
        self.init(window: window)
        SettingsWindowController.current = self
    }
    
    deinit {
        SettingsWindowController.current = nil
    }
}

struct SettingsView: View {
    @AppStorage(Preferences.minutesUntilCloseKey) var minutesUntilClose: Int = Preferences.defaultMinutesUntilClose
    @AppStorage("showCloseButton") var showCloseButton: Bool = false

    init() {
        Preferences.migrateIdleTimePreferenceIfNeeded()
    }
    
    var appVersion: String {
        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            return version
        }
        return ""
    }
    
    var appBuildNumber: String {
        if let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String {
            return buildNumber
        }
        return ""
    }

    private var idleHours: Int {
        minutesUntilClose / 60
    }

    private var idleMinutes: Int {
        minutesUntilClose % 60
    }

    private var idleHoursBinding: Binding<Int> {
        Binding<Int>(
            get: { idleHours },
            set: { newHours in
                updateIdleTime(hours: newHours, minutes: idleMinutes)
            }
        )
    }

    private var idleMinutesBinding: Binding<Int> {
        Binding<Int>(
            get: { idleMinutes },
            set: { newMinutes in
                updateIdleTime(hours: idleHours, minutes: newMinutes)
            }
        )
    }

    private func updateIdleTime(hours: Int, minutes: Int) {
        let clampedHours = min(max(hours, 0), Preferences.maximumMinutesUntilClose / 60)
        let clampedMinutes = min(max(minutes, 0), 59)
        let totalMinutes = (clampedHours * 60) + clampedMinutes
        minutesUntilClose = min(max(totalMinutes, 1), Preferences.maximumMinutesUntilClose)
    }
    
    var body: some View {
        VStack {
            Image("Image")
                .resizable()
                .scaledToFit()
                .frame(width: 100, height: 100)
                .padding()
            Text("MagicQuit")
                .font(.title)
                .padding()
            
            Text("\(appVersion) (\(appBuildNumber))")
            
            Divider().padding()
            
            VStack(alignment: .leading) {
                HStack {
                    Text("Startup:")
                        .frame(width: 100, alignment: .trailing)
                        .padding(.trailing, 20)
                    LaunchAtLogin.Toggle()
                }
                HStack {
                    Text("Idle time:")
                        .frame(width: 100, alignment: .trailing)
                        .padding(.trailing, 20)
                    Stepper(value: idleHoursBinding, in: 0...(Preferences.maximumMinutesUntilClose / 60), step: 1) {
                        Text("\(idleHours)h")
                            .frame(width: 40, alignment: .trailing)
                    }
                    Stepper(value: idleMinutesBinding, in: 0...59, step: 1) {
                        Text("\(idleMinutes)m")
                            .frame(width: 40, alignment: .trailing)
                    }
                    Text("until quitting")
                        .padding(.trailing, 0)
                }
                HStack {
                    Text("Quit button:")
                        .frame(width: 100, alignment: .trailing)
                        .padding(.trailing, 20)
                    Toggle(isOn: $showCloseButton) {
                        Text("Shows button to quit apps manually")
                    }
                }
            }
            .padding()
            
        }
    }
}

struct SettingsWindow: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let settingsWindowController = SettingsWindowController(rootView: SettingsView())
        settingsWindowController.showWindow(nil)
        return NSView()
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {}
}


struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView(manager: runningAppsManager)
    }
}
