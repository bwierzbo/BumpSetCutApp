//
//  LocationPickerView.swift
//  BumpSetCut
//
//  Apple Maps-backed place search for tagging where a rally was played.
//  Text search only — no CoreLocation / location permission required.
//

import SwiftUI
import MapKit

// MARK: - Picked Location

struct PickedLocation: Equatable, Hashable {
    let name: String
    let latitude: Double
    let longitude: Double
}

// MARK: - Search Model

@MainActor
@Observable
final class LocationSearchModel: NSObject, MKLocalSearchCompleterDelegate {
    var results: [MKLocalSearchCompletion] = []

    @ObservationIgnored private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.resultTypes = [.pointOfInterest, .address]
        completer.delegate = self
    }

    func update(query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            results = []
            return
        }
        completer.queryFragment = trimmed
    }

    /// Resolve an autocomplete result into a concrete place (name + coordinate).
    func resolve(_ completion: MKLocalSearchCompletion) async -> PickedLocation? {
        let search = MKLocalSearch(request: MKLocalSearch.Request(completion: completion))
        guard let response = try? await search.start(),
              let item = response.mapItems.first else { return nil }
        let coordinate = item.placemark.coordinate
        return PickedLocation(
            name: item.name ?? completion.title,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude
        )
    }

    // MARK: MKLocalSearchCompleterDelegate

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let items = completer.results
        Task { @MainActor in self.results = items }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        Task { @MainActor in self.results = [] }
    }
}

// MARK: - Picker View

struct LocationPickerView: View {
    var onPick: (PickedLocation) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var model = LocationSearchModel()
    @State private var searchText = ""
    @State private var isResolving = false

    var body: some View {
        NavigationStack {
            VStack(spacing: BSCSpacing.md) {
                BSCSearchBar(text: $searchText, placeholder: "Search parks, courts, places")
                    .padding(.horizontal, BSCSpacing.lg)
                    .padding(.top, BSCSpacing.md)
                    .onChange(of: searchText) { _, query in
                        model.update(query: query)
                    }

                if model.results.isEmpty {
                    Spacer()
                    VStack(spacing: BSCSpacing.sm) {
                        Image(systemName: "mappin.and.ellipse")
                            .font(.system(size: 36))
                            .foregroundColor(.bscTextTertiary)
                        Text("Search for the park or court you played at")
                            .font(.system(size: 14))
                            .foregroundColor(.bscTextSecondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.horizontal, BSCSpacing.xl)
                    Spacer()
                } else {
                    List(model.results, id: \.self) { result in
                        Button {
                            Task {
                                isResolving = true
                                if let picked = await model.resolve(result) {
                                    onPick(picked)
                                    dismiss()
                                }
                                isResolving = false
                            }
                        } label: {
                            HStack(spacing: BSCSpacing.md) {
                                Image(systemName: "mappin.circle.fill")
                                    .font(.system(size: 20))
                                    .foregroundColor(.bscPrimary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(result.title)
                                        .font(.system(size: 16))
                                        .foregroundColor(.bscTextPrimary)
                                    if !result.subtitle.isEmpty {
                                        Text(result.subtitle)
                                            .font(.system(size: 13))
                                            .foregroundColor(.bscTextSecondary)
                                    }
                                }
                                Spacer()
                            }
                        }
                        .listRowBackground(Color.clear)
                    }
                    .listStyle(.plain)
                }
            }
            .background(Color.bscBackground.ignoresSafeArea())
            .overlay {
                if isResolving {
                    ProgressView().tint(.bscPrimary)
                }
            }
            .navigationTitle("Add Location")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
