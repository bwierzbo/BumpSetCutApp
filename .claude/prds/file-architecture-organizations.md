---
name: file-architecture-organizations
description: Restructure codebase with layer-based architecture for scalability and developer experience
status: backlog
created: 2025-09-01T15:32:34Z
---

# PRD: File Architecture Organization

## Executive Summary

Restructure the BumpSetCut codebase using layer-based architecture principles to improve developer experience, enable feature isolation, and establish clear module boundaries that will scale effectively as we add indoor volleyball support and advanced analytics capabilities.

## Problem Statement

### What problem are we solving?
The current file organization, while functional, lacks the structural clarity needed for future scaling. As we plan to add indoor volleyball detection and advanced analytics features, we need an architecture that:
- Makes it easy to find and modify existing code
- Provides clear boundaries between different system responsibilities  
- Enables feature isolation to prevent unintended coupling
- Follows iOS development best practices for maintainability

### Why is this important now?
- **Upcoming Features**: Indoor volleyball and advanced analytics will significantly expand the codebase
- **Maintainability**: Current structure may become harder to navigate as complexity grows
- **Developer Productivity**: Better organization will make development faster and less error-prone
- **Best Practices**: Establishing proper architecture patterns before rapid expansion

## User Stories

### Primary User Persona: iOS Developer
**As an iOS developer working on BumpSetCut, I want...**

#### Story 1: Feature Development
- **User Story**: As a developer adding indoor volleyball support, I want to easily identify where sport-specific logic belongs so I can implement new features without affecting existing outdoor volleyball functionality
- **Acceptance Criteria**:
  - Sport-specific code is clearly separated from generic processing logic
  - New sport variants can be added without modifying core detection algorithms
  - Indoor/outdoor differences are encapsulated in dedicated modules

#### Story 2: Code Navigation
- **User Story**: As a developer debugging a rally detection issue, I want to quickly locate all components involved in the detection pipeline so I can trace the problem efficiently
- **Acceptance Criteria**:
  - Related functionality is co-located within clear module boundaries
  - Dependencies between modules are explicit and minimal
  - File names and directory structure reflect their responsibilities

#### Story 3: Testing & Maintenance
- **User Story**: As a developer writing unit tests, I want clear interfaces between system layers so I can test components in isolation
- **Acceptance Criteria**:
  - Each layer has well-defined protocols/interfaces
  - Dependencies can be easily mocked or stubbed
  - Business logic is separated from UI and framework code

#### Story 4: Feature Extension
- **User Story**: As a developer adding advanced analytics, I want to extend the system without modifying existing video processing logic
- **Acceptance Criteria**:
  - Analytics can be added as a new layer without touching detection/tracking code
  - Data flows through clear interfaces that support multiple consumers
  - Configuration and extensibility points are well-defined

## Requirements

### Functional Requirements

#### FR1: Layer-Based Architecture
- **Presentation Layer**: SwiftUI views, view models, and UI-specific logic
- **Business Logic Layer**: Core application logic, processing orchestration, and business rules
- **Data Layer**: File management, model definitions, and data persistence
- **Infrastructure Layer**: Framework integrations, external dependencies, and system services

#### FR2: Module Boundaries
- Each layer must have explicit interfaces (protocols) for communication
- Dependencies should flow downward (Presentation → Business → Data → Infrastructure)
- Cross-cutting concerns (logging, configuration) should be handled through dependency injection

#### FR3: Sport Variant Support
- Create abstract sport interfaces that can support both outdoor and indoor volleyball
- Encapsulate sport-specific differences in dedicated modules
- Maintain backward compatibility with existing outdoor volleyball processing

#### FR4: Analytics Integration Points
- Define extension points where analytics can tap into processing pipeline
- Create data models that support both real-time processing and historical analysis
- Establish interfaces for future reporting and visualization features

### Non-Functional Requirements

#### NFR1: Performance
- Reorganization must not impact video processing performance
- On-device processing requirement maintained (no cloud dependencies)
- Memory usage patterns should remain consistent

#### NFR2: iOS 18+ Compatibility
- Leverage iOS 18+ SwiftUI features and patterns
- Use modern Swift concurrency (async/await, actors where appropriate)
- Follow latest Apple architectural guidelines

#### NFR3: Maintainability
- File and directory names should clearly indicate their purpose
- Maximum file size: 500 lines (encourage focused responsibilities)
- Consistent naming conventions throughout all layers

#### NFR4: Testability
- Each module should be unit testable in isolation
- Dependency injection should be used for all external dependencies
- Business logic should be framework-independent

## Success Criteria

### Measurable Outcomes

#### Primary Success Metrics
1. **Code Discoverability**: Developer can locate relevant code for any feature in <30 seconds
2. **Feature Isolation**: Adding new sport variant requires <5 files touched outside the new module
3. **Module Independence**: Each layer can be unit tested with >80% code coverage
4. **Development Velocity**: Time to implement similar features decreases by 25% after reorganization

#### Quality Metrics
1. **Dependency Direction**: Zero upward dependencies between layers
2. **Interface Compliance**: All inter-layer communication goes through defined protocols
3. **File Organization**: 100% of files follow the new naming and placement conventions
4. **Documentation**: All public interfaces have comprehensive documentation

### Key Performance Indicators
- **Developer Onboarding**: New team member can understand architecture in <2 hours
- **Bug Resolution**: Time to identify bug location decreases by 30%
- **Feature Development**: Indoor volleyball implementation serves as successful proof of scalability
- **Code Quality**: Reduced cyclomatic complexity in individual modules

## Constraints & Assumptions

### Technical Constraints
- **iOS 18+ Minimum**: Can use latest SwiftUI and Swift language features
- **On-Device Processing**: All video processing must remain local (no cloud services)
- **Memory Limitations**: Mobile device memory constraints for video processing
- **Single Platform**: iOS-only focus (no cross-platform considerations needed)

### Development Constraints
- **Backward Compatibility**: Existing functionality must remain unchanged during refactoring
- **Incremental Migration**: Reorganization must be done incrementally to maintain working state
- **No Breaking Changes**: Public interfaces should remain stable during transition

### Business Assumptions
- **Feature Roadmap**: Indoor volleyball and analytics are confirmed upcoming features
- **Team Size**: Architecture should support small team development (1-3 developers)
- **Release Timeline**: Reorganization should not delay current feature development

## Out of Scope

### Explicitly NOT Building
1. **Cross-Platform Architecture**: No consideration for Android, macOS, or web versions
2. **Microservices**: Maintaining monolithic iOS app structure
3. **External Frameworks**: No introduction of large architectural frameworks (RxSwift, Combine beyond standard usage)
4. **Database Layer**: Continuing with file-based storage, not introducing CoreData/SQLite
5. **Network Layer**: No network communication or API integration architecture
6. **Multi-App Architecture**: Single app focus, not building framework for multiple apps

### Future Considerations (Not Current Scope)
- Real-time processing architecture (separate future PRD)
- Cloud sync capabilities (separate future PRD)
- Multi-platform code sharing (separate future PRD)

## Dependencies

### External Dependencies
- **Swift 6.0+**: Modern language features and concurrency
- **iOS 18 SDK**: Latest SwiftUI and framework capabilities
- **Xcode 16+**: Development environment with latest tooling

### Internal Dependencies
- **Current Codebase**: Must work with existing video processing pipeline
- **MijickCamera Integration**: Maintain camera functionality during reorganization
- **CoreML Models**: Preserve existing ML model integration patterns

### Team Dependencies
- **Architecture Review**: Technical lead approval of proposed structure
- **Testing Strategy**: QA validation that functionality remains unchanged
- **Documentation**: Updated developer documentation for new structure

## Implementation Phases

### Phase 1: Infrastructure Layer (Week 1-2)
- Extract framework integrations (CoreML, AVFoundation, MijickCamera)
- Create service protocols and implementations
- Establish dependency injection patterns

### Phase 2: Data Layer (Week 3-4)
- Reorganize models and data structures
- Create repository patterns for file management
- Establish data flow interfaces

### Phase 3: Business Logic Layer (Week 5-6)
- Extract processing orchestration from UI
- Create sport-agnostic processing interfaces
- Implement configuration and extensibility points

### Phase 4: Presentation Layer (Week 7-8)
- Reorganize SwiftUI views and view models
- Implement proper separation of concerns
- Establish UI-specific patterns and conventions

### Phase 5: Validation & Documentation (Week 9-10)
- Comprehensive testing of reorganized structure
- Performance validation
- Developer documentation and guidelines
- Proof of concept: Indoor volleyball variant implementation

## Risk Mitigation

### Technical Risks
- **Performance Regression**: Continuous performance monitoring during refactoring
- **Functionality Breaking**: Comprehensive regression testing after each phase
- **Over-Engineering**: Regular reviews to ensure practical, not theoretical improvements

### Process Risks
- **Development Disruption**: Incremental changes with working state maintained
- **Scope Creep**: Strict adherence to layer-based organization focus
- **Timeline Pressure**: Phased approach allows for adjustment if needed

This PRD establishes a clear path toward a scalable, maintainable architecture that will support BumpSetCut's growth while maintaining the excellent performance and user experience the app currently provides.