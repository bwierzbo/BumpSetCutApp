//
//  AppNavigationState.swift
//  BumpSetCut
//
//  Shared navigation state for cross-view communication (e.g. share → feed).
//

import Observation

@MainActor
@Observable
final class AppNavigationState {
    var postedHighlight: Highlight?
}
