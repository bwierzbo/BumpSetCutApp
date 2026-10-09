//
//  LabelerApp.swift
//  Labeler
//
//  RallyLab on the iPhone (same bundle ID as the Mac app; TestFlight via
//  scripts/rallylab_ios_release.sh): label BumpSetCut's training data away
//  from the Mac. Next hands you the most useful task from the training
//  plan — confirm a video's found rallies, or track a rally's ball by
//  checking only the frames the model is unsure of; Overview and Plan show
//  the dataset and the rounds; Videos lists everything and uploads videos
//  recorded on the phone. Works offline from the last sync. Data lives in
//  Supabase (labeling tables + the private "labeling" bucket), synced by
//  RallyLab on the Mac. Separate from BumpSetCut.
//

import SwiftUI

@main
struct LabelerApp: App {
    @State private var model = LabelerModel()

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .task { await model.start() }
        }
    }
}

struct RootView: View {
    @Bindable var model: LabelerModel

    var body: some View {
        Group {
            switch model.phase {
            case .starting:
                ProgressView()
            case .signedOut:
                SignInView(model: model)
            case .notLabeler:
                ContentUnavailableView {
                    Label("Not a labeler", systemImage: "lock")
                } description: {
                    Text("This account isn't on the labelers list. Add it in Supabase (public.labelers).")
                } actions: {
                    Button("Sign Out") { Task { await model.signOut() } }
                }
            case .ready:
                MainTabs(model: model)
            }
        }
        .alert("Something went wrong", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: {
            Text(model.error ?? "")
        }
    }
}

/// Next (the task queue) · Review (annotation review) · Overview · Plan · Videos. Each tab has its own
/// navigation; tasks and videos open their screens.
struct MainTabs: View {
    @Bindable var model: LabelerModel
    @State private var nextPath = NavigationPath()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView {
            Tab("Next", systemImage: "play.circle.fill") {
                NavigationStack(path: $nextPath) {
                    NextView(model: model, path: $nextPath).destinations(model)
                }
            }
            Tab("Review", systemImage: "checkmark.rectangle.stack") {
                NavigationStack { ReviewHomeView(store: model, progress: model.reviewProgress) }
            }
            .badge(model.reviewItems(.crop).count + model.reviewItems(.fullFrame).count)
            Tab("Overview", systemImage: "chart.bar.xaxis") {
                NavigationStack { OverviewView(model: model).destinations(model) }
            }
            Tab("Plan", systemImage: "point.topleft.down.to.point.bottomright.curvepath") {
                NavigationStack { PlanView(model: model).destinations(model) }
            }
            Tab("Videos", systemImage: "film.stack") {
                NavigationStack { VideoListView(model: model).destinations(model) }
            }
        }
        // Back in the app: send what's waiting and pick up the Mac's changes;
        // while it's open, take the Mac's changes every half minute.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.reload() } }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                if scenePhase == .active { await model.pullChanges() }
            }
        }
    }
}

extension View {
    /// Where tasks and videos lead.
    func destinations(_ model: LabelerModel) -> some View {
        navigationDestination(for: LabelerModel.LabelTask.self) { $0.destination(model) }
            .navigationDestination(for: LabelVideo.self) { VideoDetailView(model: model, video: $0) }
    }
}

struct SignInView: View {
    let model: LabelerModel
    @State private var email = ""
    @State private var password = ""
    @State private var busy = false
    @State private var forgot = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Email", text: $email)
                        .textContentType(.username)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                } footer: {
                    Text("Your BumpSetCut account. Only accounts on the labelers list see anything.")
                }
                Button {
                    busy = true
                    Task {
                        await model.signIn(email: email.trimmingCharacters(in: .whitespaces), password: password)
                        busy = false
                    }
                } label: {
                    HStack {
                        Text("Sign In")
                        if busy { Spacer(); ProgressView() }
                    }
                }
                .disabled(busy || email.isEmpty || password.isEmpty)
                Button("Forgot password?") { forgot = true }
                    .font(.callout)
            }
            .navigationTitle("RallyLab")
            .sheet(isPresented: $forgot) { ForgotPasswordSheet(model: model, email: email) }
        }
    }
}

/// Reset a forgotten password: a code by email, then a new password.
private struct ForgotPasswordSheet: View {
    let model: LabelerModel
    @State var email: String
    @State private var code = ""
    @State private var password = ""
    @State private var sent = false
    @State private var busy = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Email", text: $email)
                        .textContentType(.username)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(sent)
                } footer: {
                    Text(sent ? "A code is on its way to \(email). It can take a minute; check spam too."
                              : "We'll email you a code to set a new password.")
                }
                if sent {
                    Section {
                        TextField("Code from the email", text: $code)
                            .textContentType(.oneTimeCode)
                            .keyboardType(.numberPad)
                        SecureField("New password (6+ characters)", text: $password)
                            .textContentType(.newPassword)
                    }
                    Button {
                        run { await model.resetPassword(email: email.trimmingCharacters(in: .whitespaces), code: code.trimmingCharacters(in: .whitespaces), newPassword: password) }
                    } label: { busyLabel("Set Password & Sign In") }
                        .disabled(busy || code.count < 6 || password.count < 6)
                    Button("Send another code") { run(close: false) { await model.sendPasswordReset(email: email.trimmingCharacters(in: .whitespaces)) } }
                        .font(.callout).disabled(busy)
                } else {
                    Button {
                        run(close: false) {
                            let ok = await model.sendPasswordReset(email: email.trimmingCharacters(in: .whitespaces))
                            if ok { sent = true }
                            return ok
                        }
                    } label: { busyLabel("Email Me a Code") }
                        .disabled(busy || !email.contains("@"))
                }
            }
            .navigationTitle("Forgot Password")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }

    private func busyLabel(_ title: String) -> some View {
        HStack {
            Text(title)
            if busy { Spacer(); ProgressView() }
        }
    }

    /// Do `step`; close the sheet when it worked and `close`.
    private func run(close: Bool = true, _ step: @escaping () async -> Bool) {
        busy = true
        Task {
            let ok = await step()
            busy = false
            if ok && close { dismiss() }
        }
    }
}
