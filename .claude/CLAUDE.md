# CLAUDE.md

> Think carefully and implement the most concise solution that changes as little code as possible.

## USE SUB-AGENTS FOR CONTEXT OPTIMIZATION

### 1. Always use the file-analyzer sub-agent when asked to read files.
The file-analyzer agent is an expert in extracting and summarizing critical information from files, particularly log files and verbose outputs. It provides concise, actionable summaries that preserve essential information while dramatically reducing context usage.

### 2. Always use the code-analyzer sub-agent when asked to search code, analyze code, research bugs, or trace logic flow.

The code-analyzer agent is an expert in code analysis, logic tracing, and vulnerability detection. It provides concise, actionable summaries that preserve essential information while dramatically reducing context usage.

### 3. Always use the test-runner sub-agent to run tests and analyze the test results.

Using the test-runner agent ensures:

- Full test output is captured for debugging
- Main conversation stays clean and focused
- Context usage is optimized
- All issues are properly surfaced
- No approval dialogs interrupt the workflow

## Philosophy

### Error Handling

- **Fail fast** for critical configuration (missing text model)
- **Log and continue** for optional features (extraction model)
- **Graceful degradation** when external services unavailable
- **User-friendly messages** through resilience layer

### Testing

- Always use the test-runner agent to execute tests.
- Do not use mock services for anything ever.
- Do not move on to the next test until the current test is complete.
- If the test fails, consider checking if the test is structured correctly before deciding we need to refactor the codebase.
- Tests to be verbose so we can use them for debugging.


## Tone and Behavior

- Criticism is welcome. Please tell me when I am wrong or mistaken, or even when you think I might be wrong or mistaken.
- Please tell me if there is a better approach than the one I am taking.
- Please tell me if there is a relevant standard or convention that I appear to be unaware of.
- Be skeptical.
- Be concise.
- Short summaries are OK, but don't give an extended breakdown unless we are working through the details of a plan.
- Do not flatter, and do not give compliments unless I am specifically asking for your judgement.
- Occasional pleasantries are fine.
- Feel free to ask many questions. If you are in doubt of my intent, don't guess. Ask.

## ABSOLUTE RULES:

- NO PARTIAL IMPLEMENTATION
- NO SIMPLIFICATION : no "//This is simplified stuff for now, complete implementation would blablabla"
- NO CODE DUPLICATION : check existing codebase to reuse functions and constants Read files before writing new functions. Use common sense function name to find them easily.
- NO DEAD CODE : either use or delete from codebase completely
- IMPLEMENT TEST FOR EVERY FUNCTIONS
- NO CHEATER TESTS : test must be accurate, reflect real usage and be designed to reveal flaws. No useless tests! Design tests to be verbose so we can use them for debuging.
- NO INCONSISTENT NAMING - read existing codebase naming patterns.
- NO OVER-ENGINEERING - Don't add unnecessary abstractions, factory patterns, or middleware when simple functions would work. Don't think "enterprise" when you need "working"
- NO MIXED CONCERNS - Don't put validation logic inside API handlers, database queries inside UI components, etc. instead of proper separation
- NO RESOURCE LEAKS - Don't forget to close database connections, clear timeouts, remove event listeners, or clean up file handles

## RECENT ARCHITECTURAL IMPROVEMENTS

### Video Processing & Tracking System

#### Processing State Management
- **VideoMetadata Enhancement**: Added `isProcessed`, `originalVideoId`, and `processedVideoIds` fields to track processing relationships
- **Backwards Compatibility**: Implemented custom `init(from decoder:)` with `decodeIfPresent` to handle existing data gracefully
- **Processing Prevention**: Only original videos can be processed; processed videos and videos with existing versions are blocked

#### UI Components
- **Dual Processing Buttons**: Replaced toggle with separate "AI Processing" and "Debug Processing" buttons in ProcessVideoView
- **Processing Status Indicators**: Added visual indicators throughout UI showing video processing state (Original, Processed, X versions)
- **Context-Aware Menus**: Process option only appears for videos that can be processed

#### Data Integrity & Cleanup
- **Relationship Management**: When deleting processed videos, their IDs are removed from original video's `processedVideoIds` array
- **Cascade Deletion**: When deleting original videos, all associated processed versions are automatically cleaned up
- **Debug Data Cleanup**: Debug JSON files are removed when processed videos are deleted

### UI/UX Improvements

#### Grid Layout Consistency
- **Fixed Sizing**: VideoCardView uses fixed height constraints (`minHeight: 70, maxHeight: 70`) for info sections
- **Maximum Card Height**: Added 200px max height constraint to ensure uniform grid cell sizes
- **Consistent Display**: All videos (processed/uploaded) now display identically in grid view

#### Landscape Mode Optimization
- **Adaptive Grid Columns**: 2 columns in portrait, 3 columns in landscape for both folders and videos
- **Responsive Typography**: Titles and headers scale down in landscape to preserve vertical space
- **Optimized Spacing**: Tighter spacing (12px vs 16px) and increased padding (20px vs 16px) in landscape
- **Search Bar Positioning**: Fixed search bar to stay under navigation bar in landscape using `navigationBarDrawer` placement

#### Toolbar & Navigation
- **Improved Spacing**: Reduced toolbar button spacing from 16px to 12px for professional look
- **Consistent Button Sizing**: Fixed 32x32 frames for all toolbar icons with uniform typography (16pt, medium weight)
- **Better Edge Padding**: Added trailing padding to toolbar button group

### Data Architecture

#### MediaStore Enhancements
- **Processing Relationships**: New `addProcessedVideo()` method properly links processed videos to originals
- **Cleanup Methods**: Enhanced `deleteVideo()` with `cleanupProcessedVideoRelationships()` for data integrity
- **Backwards Compatible Storage**: Custom encoding/decoding ensures old data remains accessible

#### Configuration System
- **ProcessorConfig Updates**: Temporarily disabled `enableEnhancedPhysics` to resolve processing failures
- **Parameter Validation**: Added comprehensive validation methods and error handling
- **Debug Integration**: Enhanced debug data persistence with session tracking

### Best Practices Established

#### State Management
- **Unidirectional Data Flow**: Clear separation between data layer (MediaStore) and UI components
- **Computed Properties**: Processing status calculated from data rather than stored separately
- **Reactive Updates**: UI automatically reflects data changes through proper binding

#### Error Handling
- **Graceful Degradation**: Missing fields default to safe values during decoding
- **User-Friendly Messages**: Clear status messages for why videos can't be processed
- **Logging**: Comprehensive console output for debugging processing operations

#### Performance
- **Lazy Loading**: Grid views use LazyVGrid for efficient rendering of large collections
- **Minimal Recomputation**: Geometry calculations cached and reused within view updates
- **Resource Management**: Proper cleanup of temporary files and debug data

### Testing & Validation

#### Integration Testing
- **Processing Pipeline**: Validated end-to-end video processing with relationship tracking
- **UI Consistency**: Verified grid sizing across different video types and orientations
- **Data Migration**: Tested backwards compatibility with existing video libraries

#### Manual Testing Patterns
- **Processing State Validation**: Verify correct status indicators and menu options
- **Deletion Integrity**: Confirm proper cleanup when deleting processed videos
- **Landscape Functionality**: Test all features work correctly in landscape orientation

## IMPORTANT TECHNICAL NOTES

### Video Processing Pipeline
- **Enhanced Physics**: Currently disabled (`enableEnhancedPhysics = false`) due to overly strict validation causing processing failures
- **Processing Prevention Logic**: Videos are blocked from reprocessing using `canBeProcessed` computed property
- **Debug Data**: JSON files stored in `.debug_data` directory with UUID-based naming for session tracking

### UI Architecture Patterns
- **GeometryReader Usage**: Implemented throughout view hierarchy for responsive layout calculations
- **Computed Properties**: Status indicators use computed properties for reactive updates instead of stored state
- **Fixed Constraints**: Critical for grid consistency - always use both min/max height constraints for uniform sizing

### Data Migration Strategy
- **Backwards Compatibility**: Always use `decodeIfPresent` for new fields with sensible defaults
- **Relationship Integrity**: When adding foreign key relationships, ensure cleanup methods are implemented
- **Testing Migration**: Always test with existing data to ensure no breaking changes

### Performance Considerations
- **Lazy Collections**: Use LazyVGrid/LazyVStack for large collections to prevent performance issues
- **Geometry Caching**: Calculate orientation once per view update and reuse the result
- **Resource Cleanup**: Always implement proper cleanup for temporary files, especially in processing pipeline

### SwiftUI Best Practices Applied
- **Single Source of Truth**: VideoMetadata serves as the authoritative source for all video state
- **Declarative UI**: Status indicators and menus computed from data state, not managed separately  
- **Proper Modifiers**: Search placement and toolbar positioning use appropriate platform-specific modifiers

# important-instruction-reminders
Do what has been asked; nothing more, nothing less.
NEVER create files unless they're absolutely necessary for achieving your goal.
ALWAYS prefer editing an existing file to creating a new one.
NEVER proactively create documentation files (*.md) or README files. Only create documentation files if explicitly requested by the User.
