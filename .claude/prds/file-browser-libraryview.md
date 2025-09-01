---
name: file-browser-libraryview
description: Enhanced video library with folder organization, sorting, renaming, and improved upload experience
status: backlog
created: 2025-09-01T18:53:13Z
---

# PRD: File Browser LibraryView

## Executive Summary

Transform the existing LibraryView into a comprehensive video file management system that allows users to organize their volleyball video collection with folders, sorting, renaming capabilities, and an enhanced upload experience. This upgrade maintains all current video processing functionality while providing professional-grade file organization tools.

## Problem Statement

**Current Pain Points:**
- Users can only view videos in a flat, chronological list
- No ability to organize videos into folders by tournament, team, date, etc.
- Cannot rename videos from generic filenames to meaningful names
- Basic upload experience without progress feedback or naming
- Limited sorting and navigation options for growing video libraries
- No hierarchical organization for users with many games/sessions

**Why This Matters Now:**
As users capture more volleyball games, the current flat file structure becomes unwieldy. Users need professional file management tools to organize their growing video libraries effectively, making it easier to find specific games and maintain organized collections.

## User Stories

### Primary Persona: Volleyball Coach/Player
"As a volleyball coach, I want to organize my game recordings into folders by tournament and team so I can quickly find specific matches for analysis."

### Core User Journeys

**Journey 1: Organizing Existing Videos**
1. User opens LibraryView and sees current video collection
2. User creates folders (e.g., "Championships 2024", "Practice Sessions")
3. User moves videos into appropriate folders via drag-and-drop or menu selection
4. User renames videos from generic names to descriptive ones ("Final vs Eagles")

**Journey 2: Enhanced Upload with Organization**
1. User taps upload button and selects video from photo library
2. System shows upload progress popup with cancel option
3. User enters meaningful name for the video during upload
4. User optionally selects destination folder or creates new one
5. Video appears in chosen location, ready for processing

**Journey 3: Advanced Navigation and Processing**
1. User browses folder hierarchy to find specific game
2. User uses sorting options (date, name, size, processed status)
3. User long-presses video tile or taps menu button (⋮) for context menu
4. User selects "Process with AI" or "Debug Mode" maintaining current pipeline
5. User can preview, rename, move, or delete from the same context menu

## Requirements

### Functional Requirements

**Core File Management**
- Create, rename, and delete folders in hierarchical structure
- Move videos between folders via drag-and-drop or menu selection
- Rename videos with inline editing or popup dialog
- Navigate folder hierarchy with breadcrumb navigation
- Search functionality across all videos and folders

**Enhanced Upload Experience**
- Upload progress popup with percentage and cancel option
- Video naming dialog during upload process
- Folder selection for new uploads
- Thumbnail generation preview during upload

**Video Organization & Sorting**
- Sort by: Name (A-Z, Z-A), Date (Newest, Oldest), File Size, Processing Status
- Filter by: Processed/Unprocessed, Date Range
- Grid and List view toggles
- Folder-first sorting (folders appear before videos)

**Preserved Processing Integration**
- Maintain current ProcessVideoView integration
- Keep existing AI processing and Debug mode buttons/functionality
- Preserve video preview capabilities
- Maintain delete functionality with confirmation

**Enhanced Interaction Methods**
- Long-press on video tiles for context menu
- Triple-dot menu button (⋮) on each video tile
- Context menu options: Preview, Process, Debug, Rename, Move, Delete
- Single video selection only (no batch operations)

### Non-Functional Requirements

**Performance**
- Smooth scrolling with 60fps even with 100+ videos
- Thumbnail loading with progressive enhancement
- Folder operations complete within 500ms
- Upload progress updates every 100ms

**User Experience**
- Intuitive folder navigation with iOS-native patterns
- Consistent with existing app design language
- Haptic feedback for drag-and-drop and long-press actions
- Accessibility support with VoiceOver compatibility

**Data Integrity**
- Maintain video file references when moving between folders
- Preserve processing state and metadata during organization
- Automatic backup of folder structure
- Graceful handling of missing or corrupted video files

## Success Criteria

**User Engagement Metrics**
- 80% of users create at least one folder within first week
- Average folder depth of 2+ levels for active users  
- 60% of uploaded videos are renamed from default names
- Reduced time to find specific videos by 50%

**Technical Metrics**
- Zero data loss during file operations
- Upload success rate > 99%
- Video processing pipeline maintains current performance
- App launch time increases by less than 200ms with file organization

**User Satisfaction**
- User feedback scores improve for "organization" and "ease of use"
- Support tickets related to "can't find videos" reduce by 70%
- Power users (20+ videos) retention increases

## Constraints & Assumptions

**Technical Constraints**
- Single video selection only (no batch processing)
- Must preserve existing video processing pipeline
- iOS document directory storage limitations
- Memory constraints for large video collections

**Design Constraints**
- Must maintain current app visual design system
- Context menus limited to 6-8 options for usability
- Folder depth limited to 5 levels for performance

**Timeline Constraints**
- Must not break existing LibraryView functionality during development
- Backwards compatibility for users with existing video collections

## Out of Scope

**Explicitly NOT Building**
- Multiple video selection or batch operations
- Cloud storage integration (iCloud, Dropbox, Google Drive)
- Video editing capabilities beyond current processing
- Sharing videos to external apps
- Advanced filtering (tags, categories, ratings)
- Video metadata editing beyond renaming
- Automatic folder organization based on video content
- Export/Import of folder structures

## Dependencies

**Internal Dependencies**
- Current MediaStore architecture for file management
- Existing ProcessVideoView integration
- Video thumbnail generation system
- Current upload and photo library access implementation

**External Dependencies**
- iOS Photos Framework for library access
- iOS File Management APIs
- SwiftUI navigation and animation systems
- iOS Document Directory permissions

**Team Dependencies**
- UI/UX design for new interaction patterns
- Testing with various video collection sizes
- Performance validation on older iOS devices

## Technical Implementation Notes

**Folder Structure**
- Use subdirectories within current Documents/BumpSetCut structure
- Maintain flat file references with folder metadata
- JSON manifest file for folder hierarchy and video metadata

**Context Menu Implementation**
- SwiftUI ContextMenu for long-press interactions
- Custom overlay for triple-dot button menus
- Consistent menu styling across interaction methods

**Upload Enhancement**
- AsyncSequence for upload progress tracking
- Custom progress popup using existing MijickPopups patterns
- Video naming modal integrated with upload flow

**Data Migration**
- Automatic migration of existing videos to root folder
- Preserve all existing video processing states and metadata
- Graceful fallback for missing folder structure

## Acceptance Criteria

### Core Functionality
- [ ] Users can create, rename, and delete folders
- [ ] Videos can be moved between folders via multiple interaction methods
- [ ] Videos can be renamed with inline editing
- [ ] Upload shows progress and allows naming
- [ ] All existing processing functionality preserved
- [ ] Search works across entire video collection

### User Experience
- [ ] Long-press and triple-dot menu provide consistent options
- [ ] Smooth navigation between folders with breadcrumbs
- [ ] Grid/List view toggle works in all folders
- [ ] Sorting options work correctly in folder context
- [ ] Single video selection enforced throughout

### Technical Requirements
- [ ] Zero data loss during file operations
- [ ] Performance maintained with 100+ videos
- [ ] Backwards compatibility with existing video collections
- [ ] Proper error handling for edge cases
- [ ] Memory usage remains within acceptable limits

## Next Steps

1. **Design Phase**: Create mockups for folder navigation, context menus, and upload flow
2. **Technical Planning**: Define data model changes and migration strategy
3. **Implementation**: Start with core folder operations, then enhance upload experience
4. **Testing**: Validate with large video collections and various usage patterns
5. **Migration**: Plan smooth transition for existing users