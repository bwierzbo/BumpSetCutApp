//
//  LabelerApp.swift
//  Labeler
//
//  RallyLab on the iPhone (same bundle ID as the Mac app, one App Store
//  Connect record): a small app for labeling BumpSetCut's training data away from the
//  Mac: mark every rally's start and end in the videos of a RallyLab
//  project, and upload videos recorded on the phone for RallyLab to pull in.
//  Separate from BumpSetCut; installed from Xcode. Data lives in Supabase
//  (labeling tables + the private "labeling" bucket), synced by RallyLab.
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
                VideoListView(model: model)
            }
        }
        .alert("Something went wrong", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: {
            Text(model.error ?? "")
        }
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
