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
            }
            .navigationTitle("RallyLab")
        }
    }
}
