# Technology Stack

**Analysis Date:** 2026-01-24

## Languages

**Primary:**
- Swift 5.0 - Native iOS application development

**Secondary:**
- None

## Runtime

**Environment:**
- iOS 18.0+ (minimum deployment target)
- Xcode 16.0+

**Package Manager:**
- Swift Package Manager (SPM)
- Lockfile: Present at `BumpSetCut.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`

## Frameworks

**Core:**
- SwiftUI - UI framework for all views
- AVFoundation - Video processing, playback, and frame extraction
- CoreML - Machine learning model integration (YOLO volleyball detection)
- Vision - Computer vision framework for object detection
- CoreGraphics - Graphics rendering and coordinate transformations
- CoreMedia - Media sample buffer handling and time management
- UIKit - iOS platform integration (photo picker, image utilities)
- Observation - SwiftUI state management with `@Observable` macro

**Testing:**
- XCTest - Unit and integration testing framework (located in `BumpSetCutTests/`)

**Build/Dev:**
- Xcode Build System - Native iOS build tooling

## Key Dependencies

**Critical:**
- MijickCamera 3.0.2 - Camera capture interface for recording volleyball footage
  - Repository: `https://github.com/Mijick/Camera`

- MijickPopups 4.0.1 - Modal dialog and popup UI components
  - Repository: `https://github.com/Mijick/Popups`

- MijickTimer 2.0.0 - Timer utilities for video recording
  - Repository: `https://github.com/Mijick/Timer`

**Infrastructure:**
- bestv2.mlpackage - Custom YOLO CoreML model for volleyball detection (located in `BumpSetCut/Resources/ML/`)
- Inter font family (Regular, Bold) - Custom typography loaded via `Info.plist`

## Configuration

**Environment:**
- No environment variables required
- All configuration is compile-time or file-based
- ProcessorConfig class manages video processing parameters in code

**Build:**
- `BumpSetCut.xcodeproj/project.pbxproj` - Xcode project configuration
- `BumpSetCut/Info.plist` - App metadata and permissions (camera, microphone, photo library)
- Development Team: 2J4SZTDKKP
- Bundle Identifier: wplus12.BumpSetCut
- Marketing Version: 1.0
- Build System: Xcode 26.0 (LastUpgradeCheck = 2600)

**Required Permissions:**
- NSCameraUsageDescription: "Record Volleyball Footage"
- NSMicrophoneUsageDescription: "For video Audio"
- NSPhotoLibraryUsageDescription: "Access Volleyball Footage"

## Platform Requirements

**Development:**
- macOS with Xcode 16.0+
- iOS Simulator or physical iOS device (iPhone/iPad)
- Swift 5.0+ compiler

**Production:**
- iOS 18.0 or later
- iPhone and iPad (Universal app, TARGETED_DEVICE_FAMILY = "1,2")
- All interface orientations supported (Portrait, Landscape, UpsideDown)
- ANE (Apple Neural Engine) or GPU recommended for CoreML inference (config.computeUnits = .all)

---

*Stack analysis: 2026-01-24*
