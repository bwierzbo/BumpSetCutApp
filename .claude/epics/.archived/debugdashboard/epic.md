---
name: debugdashboard
status: completed
created: 2025-09-03T16:44:57Z
updated: 2025-09-04T01:14:29Z
completed: 2025-09-04T01:14:29Z
progress: 100%
prd: .claude/prds/debugdashboard.md
github: [Will be updated when synced to GitHub]
---

# Epic: Debug Dashboard Integration

## Overview

Integrate existing TrajectoryDebugger backend and DebugDashboardView UI into the BumpSetCut video processing workflow. This is primarily a **UI integration project** (80% already built) that connects comprehensive debug visualization capabilities to a developer-accessible workflow through ProcessVideoView.

**Key Insight**: The heavy lifting (metrics collection, visualization, parameter tuning) is complete. Focus on minimal integration points to enable post-processing debug analysis.

## Architecture Decisions

**Integration Strategy**: Extend existing ProcessVideoView workflow rather than creating new debug-specific flows
- **Rationale**: Maintains familiar user experience and leverages existing video processing UI patterns

**Data Persistence**: Store debug data as extended video metadata rather than separate database
- **Rationale**: Ensures automatic cleanup and maintains data locality with processed videos

**Conditional UI**: Debug features only visible when debug mode enabled and debug data exists
- **Rationale**: Keeps UI clean for regular users while providing developer access when needed

**Performance-First**: Debug mode explicitly opt-in with clear performance impact messaging
- **Rationale**: Maintains production app performance while enabling comprehensive debugging when needed

## Technical Approach

### Frontend Components (SwiftUI Integration)

**ProcessVideoView Enhancements**:
- Debug mode toggle with performance disclaimer
- Debug status indicator during processing
- Conditional "View Debug Dashboard" button in results view
- Navigation to existing DebugDashboardView

**State Management**:
- `@State private var isDebugEnabled: Bool = false`
- `@State private var hasDebugData: Bool = false`
- Pass TrajectoryDebugger instance to DebugDashboardView

**Navigation Pattern**:
```swift
.navigationDestination(isPresented: $showingDebugDashboard) {
    DebugDashboardView(debugger: trajectoryDebugger)
}
```

### Backend Services (Minimal Changes)

**VideoProcessor Integration**:
- Conditional TrajectoryDebugger initialization in debug mode
- Pass debugger instance through processing pipeline
- Enhanced logging when debug enabled

**Data Persistence Strategy**:
- Extend video metadata structure to include debug data reference
- Store serialized debug data alongside video files
- Implement cleanup in video deletion workflow

**No New Services Required**: Leverage existing TrajectoryDebugger and DebugDashboardView

### Infrastructure

**Storage**: Extend existing video metadata system
**Performance**: Debug mode opt-in to avoid production impact  
**Monitoring**: Leverage existing TrajectoryDebugger performance tracking

## Implementation Strategy

**Development Philosophy**: Maximum leverage of existing code, minimal new development

**Phase 1 - Core Integration (MVP)**:
1. Add debug toggle to ProcessVideoView
2. Integrate TrajectoryDebugger with VideoProcessor in debug mode
3. Add dashboard access button to results view
4. Wire navigation to existing DebugDashboardView

**Phase 2 - Data Persistence**:
1. Extend video metadata for debug data storage
2. Implement debug data lifecycle with video deletion
3. Add session persistence across app restarts

**Risk Mitigation**:
- Debug mode failures isolated from video processing
- Graceful degradation when debug data unavailable
- Performance monitoring to ensure <5% overhead target

## Task Breakdown Preview

High-level task categories (targeting ≤6 tasks total):

- [ ] **UI Integration**: Add debug toggle and dashboard access to ProcessVideoView
- [ ] **Debug Mode Workflow**: Connect TrajectoryDebugger to VideoProcessor for debug-enabled processing  
- [ ] **Navigation & Dashboard**: Wire existing DebugDashboardView into post-processing workflow
- [ ] **Data Persistence**: Extend video metadata system for debug data storage and lifecycle
- [ ] **Export Functionality**: Implement JSON/CSV export features in dashboard
- [ ] **Testing & Validation**: Comprehensive testing of debug workflow and performance impact

## Dependencies

**Internal Dependencies**:
- Existing TrajectoryDebugger (Domain/Debug/TrajectoryDebugger.swift) ✅ Complete
- Existing DebugDashboardView (Presentation/Debug/DebugDashboardView.swift) ✅ Complete
- ProcessVideoView for UI integration points
- VideoProcessor for debug mode integration
- MediaStore for metadata and lifecycle management

**External Dependencies**:
- SwiftUI Charts framework ✅ Already integrated
- AVFoundation for video processing ✅ Already available

**No Blocking Dependencies**: All required components exist and are functional

## Success Criteria (Technical)

**Performance Benchmarks**:
- Debug mode adds <5% processing overhead (measured via PerformanceMetric)
- Dashboard loads within 2 seconds of navigation
- Export completes within 10 seconds for typical debug sessions

**Quality Gates**:
- Zero crashes during debug workflow testing
- 100% successful debug data persistence/retrieval
- All 5 dashboard tabs functional with real data
- Export validation: JSON deserializable, CSV format correct

**Acceptance Criteria**:
- Developer can enable debug mode, process video, access dashboard within 3 taps
- Debug data automatically cleaned up when video deleted
- Parameter tuning interface functional with live feedback
- Console logging enhanced when debug mode active

## Estimated Effort

**Overall Timeline**: 1-2 development sessions
**Complexity Level**: Low-Medium (primarily integration, not new development)

**Resource Requirements**:
- Single developer (80% existing code leverage)
- Focus on UI integration and data flow rather than algorithm development

**Critical Path Items**:
1. ProcessVideoView debug mode integration (highest impact)
2. VideoProcessor + TrajectoryDebugger connection (core functionality)
3. Data persistence implementation (enables full workflow)

**Low-Risk Implementation**: High percentage of reusable components significantly reduces development risk and timeline uncertainty.

## Tasks Created
- [ ] 001.md - UI Integration: Debug Toggle and Dashboard Access (parallel: false)
- [ ] 002.md - Debug Mode Workflow: VideoProcessor Integration (parallel: false)
- [ ] 003.md - Navigation and Dashboard Connection (parallel: true)
- [ ] 004.md - Data Persistence: Video Metadata Extension (parallel: false)
- [ ] 005.md - Export Functionality: JSON/CSV Data Export (parallel: true)
- [ ] 006.md - Testing and Validation: Debug Workflow Verification (parallel: false)

**Total tasks**: 6
**Parallel tasks**: 2 (tasks 003, 005)
**Sequential tasks**: 4 (critical path: 001 → 002 → 004 → 006)
**Estimated total effort**: 9.5 days (1.5-2 development sessions)