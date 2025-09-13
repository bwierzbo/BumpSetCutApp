---
name: file-browser-libraryview
status: completed
created: 2025-09-01T18:55:42Z
completed: 2025-09-02T23:31:17Z
progress: 100%
prd: .claude/prds/file-browser-libraryview.md
github: https://github.com/bwierzbo/BumpSetCutApp/issues/11
last_sync: 2025-09-02T23:31:17Z
---

# Epic: File Browser LibraryView

## Overview

Enhance the existing LibraryView with folder organization, video management, and improved upload experience while preserving all current video processing functionality. This implementation leverages the existing clean layer architecture and MediaStore patterns to minimize complexity.

## Architecture Decisions

### Data Model Strategy
- **Extend existing MediaStore** in Data layer rather than creating new components
- **Folder metadata as JSON manifest** alongside existing file storage approach  
- **Preserve current video processing pipeline** completely unchanged
- **Single source of truth** pattern with MediaStore managing both files and folder structure

### UI Component Approach
- **Enhance existing LibraryView** rather than replacing it
- **Reuse existing ProcessVideoView integration** patterns
- **Extend current SwiftUI components** (StoredVideo, ActionButton) with new capabilities
- **Leverage MijickPopups** for upload progress and naming dialogs

### File System Design
- **Subdirectories within Documents/BumpSetCut** for physical folder structure
- **Backward compatibility** by treating root as default folder for existing videos
- **Atomic operations** for move/rename to prevent data corruption

## Technical Approach

### Frontend Components (Presentation Layer)
- **Enhanced LibraryView**: Add folder navigation, breadcrumbs, sorting controls
- **FolderBrowserView**: New component for hierarchical folder navigation  
- **VideoContextMenu**: Reusable context menu component for video operations
- **UploadProgressPopup**: Progress tracking popup using MijickPopups patterns
- **VideoNamingDialog**: Modal for naming videos during upload

### Backend Services (Domain Layer)
- **No new domain services needed** - leverage existing VideoProcessor integration
- **Preserve ProcessVideoView** functionality exactly as-is
- **Maintain existing video processing pipeline** without modification

### Data Management (Data Layer)
- **Extended MediaStore**: Add folder operations (create, rename, delete, move)
- **FolderManifest**: JSON-based metadata for folder hierarchy and video organization
- **VideoMetadata**: Extend existing models with folder location and custom names
- **Migration service**: One-time migration for existing video collections

### Infrastructure Layer
- **File system utilities**: Leverage existing Infrastructure/System components
- **No new external integrations** required

## Implementation Strategy

### Phase 1: Core Data Model (Week 1)
- Extend MediaStore with folder management capabilities
- Implement FolderManifest for metadata storage
- Add video naming and folder location properties
- Create migration logic for existing videos

### Phase 2: Basic UI Enhancement (Week 1-2)  
- Enhance LibraryView with folder navigation and breadcrumbs
- Add create/rename/delete folder operations
- Implement basic sorting and view toggle functionality
- Preserve all existing video processing integrations

### Phase 3: Advanced Interactions (Week 2)
- Implement context menus (long-press and triple-dot button)
- Add drag-and-drop or menu-based video moving
- Create video renaming interface
- Add search functionality across folders

### Phase 4: Upload Enhancement (Week 2-3)
- Implement upload progress tracking with cancellation  
- Add video naming dialog during upload
- Create folder selection for new uploads
- Ensure thumbnail generation works in folder context

### Phase 5: Polish & Testing (Week 3)
- Performance optimization for large collections
- Error handling and edge cases
- Comprehensive testing with existing video processing
- User acceptance testing

## Tasks Created
- [ ] #12 - Data Model Extension (parallel: false)
- [ ] #13 - Migration & Compatibility (parallel: false)
- [ ] #14 - Folder Operations (parallel: false)
- [ ] #15 - Enhanced LibraryView (parallel: true)
- [ ] #16 - Video Management (parallel: true)
- [ ] #17 - Upload Enhancement (parallel: true)
- [ ] #18 - Search & Sorting (parallel: true)
- [ ] #19 - Testing & Performance (parallel: false)

Total tasks: 8
Parallel tasks: 4
Sequential tasks: 4
Estimated total effort: 84 hours (3.5 weeks with 1 developer, 2 weeks with parallel development)
## Dependencies

### Internal Dependencies
- Current MediaStore architecture (Data layer)
- Existing LibraryView and ProcessVideoView (Presentation layer)  
- StoredVideo and ActionButton components
- MijickPopups integration for modals
- Current video thumbnail generation system

### External Dependencies
- iOS FileManager for folder operations
- SwiftUI ContextMenu and DragGesture APIs
- iOS Photos Framework (existing upload functionality)
- No new external frameworks required

### No Breaking Changes
- All existing video processing functionality preserved
- Current LibraryView behavior maintained as fallback
- Existing video collections work without modification

## Success Criteria (Technical)

### Performance Benchmarks
- LibraryView loads within 500ms with 100+ videos across multiple folders
- Folder operations (create, rename, delete) complete within 300ms  
- Video move operations complete within 1 second
- Upload progress updates smoothly without UI blocking
- Memory usage increases by less than 10% with folder structure

### Quality Gates
- Zero data loss during any folder or video operations
- All existing video processing tests continue to pass
- New folder operations have 100% test coverage
- Backward compatibility verified with existing video collections
- UI remains responsive during long operations

### Acceptance Criteria
- Users can organize videos into hierarchical folders (5 levels deep)
- All current ProcessVideoView functionality works identically in folder context
- Upload experience enhanced with progress and naming without breaking existing flow
- Search finds videos across all folders quickly
- Context menus provide consistent experience via long-press and triple-dot button

## Estimated Effort

### Overall Timeline
- **3 weeks development time** (based on leveraging existing architecture)
- **1 developer** (can work within established layer boundaries)
- **Parallel development possible** due to clean architecture separation

### Resource Requirements
- Primary iOS developer familiar with existing codebase
- QA testing with various video collection sizes
- No additional infrastructure or external service setup required

### Critical Path Items
1. MediaStore extension and data model changes (foundation for everything else)
2. LibraryView enhancement (core UI that other features build on)  
3. Upload enhancement (most user-visible improvement)
4. Testing and migration (ensures no regressions)

## Risk Mitigation

### Low Risk Implementation
- **Leverage existing patterns** throughout the codebase
- **No changes to video processing pipeline** eliminates major risk area
- **Incremental enhancement** rather than replacement reduces integration risk
- **Backward compatibility** ensures existing users unaffected

### Complexity Reduction
- **Single video selection only** eliminates complex batch operation logic
- **JSON manifest approach** simpler than database integration
- **Extend existing components** rather than creating parallel systems
- **Reuse MijickPopups** patterns for new modals
