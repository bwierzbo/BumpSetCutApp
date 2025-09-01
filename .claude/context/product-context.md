---
created: 2025-09-01T15:19:09Z
last_updated: 2025-09-01T15:19:09Z
version: 1.0
author: Claude Code PM System
---

# Product Context

## Product Overview

**BumpSetCut** is an intelligent iOS app that automatically detects and extracts volleyball rally segments from recorded videos using computer vision and machine learning.

## Target Users

### Primary Users
**Volleyball Players & Teams**
- **Needs**: Analyze gameplay, identify key rally moments, create highlight reels
- **Pain Points**: Manual video editing is time-consuming, hard to identify exact rally boundaries
- **Usage Patterns**: Record games/practices, process videos for review and improvement

**Volleyball Coaches**  
- **Needs**: Create training materials, analyze team performance, identify teachable moments
- **Pain Points**: Spending hours manually scrubbing through game footage
- **Usage Patterns**: Bulk processing of game recordings, extracting specific plays for instruction

### Secondary Users
**Sports Analysts & Content Creators**
- **Needs**: Rapid content generation, statistical analysis of volleyball matches
- **Pain Points**: Labor-intensive manual video segmentation
- **Usage Patterns**: Professional content creation, match analysis workflows

**Recreational Players**
- **Needs**: Share exciting moments, create social media content
- **Pain Points**: Technical complexity of video editing apps
- **Usage Patterns**: Casual recording and sharing of best moments

## Core Functionality

### Automated Rally Detection
**What It Does:**
- Analyzes volleyball videos frame-by-frame to identify when rallies start and end
- Uses computer vision to track ball movement and detect active gameplay periods
- Applies physics-based validation to ensure detected ball trajectories are realistic

**User Value:**
- Eliminates manual scrubbing through hours of footage
- Captures entire rally sequences automatically
- Maintains consistent quality of detection across different video conditions

### Intelligent Video Segmentation
**What It Does:**
- Extracts only the active rally portions from source videos
- Adds appropriate padding before/after rallies for context
- Creates clean, watchable segments ready for sharing or analysis

**User Value:**
- Dramatically reduces file sizes by removing dead time
- Creates immediately shareable content
- Preserves important context around each rally

### Debug Visualization Mode
**What It Does:**
- Provides annotated video showing detection algorithm in action
- Visualizes ball tracking, trajectory prediction, and decision boundaries
- Enables users to understand and validate the automated processing

**User Value:**
- Builds trust in automated detection system
- Allows fine-tuning of detection parameters
- Educational value for understanding volleyball analysis

## Use Cases

### Game Analysis Workflow
1. **Record**: Capture full volleyball match or practice session
2. **Process**: Run video through BumpSetCut automated detection
3. **Review**: Watch extracted rally segments to analyze gameplay
4. **Share**: Distribute highlights to team members or coaches

### Training Material Creation
1. **Bulk Processing**: Process multiple game recordings simultaneously
2. **Curation**: Review extracted rallies for teaching opportunities  
3. **Organization**: Build library of specific play types or techniques
4. **Instruction**: Use segments in practice sessions and team meetings

### Content Creation Pipeline
1. **Capture**: Record volleyball content for social media or analysis
2. **Automated Editing**: Extract best moments without manual editing
3. **Enhancement**: Apply additional editing to exported segments as needed
4. **Distribution**: Share polished content across platforms

### Performance Tracking
1. **Consistent Recording**: Document regular practices and games
2. **Automated Processing**: Build database of rally segments over time
3. **Trend Analysis**: Track team performance and individual improvement
4. **Historical Review**: Access and compare performance across time periods

## User Experience Principles

### Automation-First
- Minimize manual intervention required from users
- Provide intelligent defaults that work well out-of-the-box
- Make advanced configuration optional, not required

### Trust Through Transparency
- Debug mode shows exactly what the algorithm detected
- Clear progress indicators during processing
- Obvious success/failure states with helpful error messages

### Mobile-Native Experience  
- Designed specifically for iOS touch interface
- Optimized for portrait and landscape orientations
- Seamless integration with device camera and photo library

### Performance-Conscious
- On-device processing protects user privacy
- Efficient algorithms minimize processing time and battery usage
- Smart optimizations (frame skipping in debug mode) balance quality and speed

## Success Metrics

### Primary Success Indicators
- **Detection Accuracy**: Percentage of actual rallies correctly identified
- **Processing Speed**: Time required to process typical game video
- **User Retention**: Frequency of repeat usage by volleyball community
- **Content Generation**: Volume of rally segments successfully extracted

### User Satisfaction Metrics
- **False Positive Rate**: Incorrectly identified rally segments
- **False Negative Rate**: Missed actual rally sequences  
- **Processing Reliability**: Successful completion rate of video processing
- **Ease of Use**: User ability to successfully process videos without instruction

## Competitive Advantages

### Technical Differentiators
- **Sport-Specific Intelligence**: Purpose-built for volleyball rather than generic sports
- **Physics-Based Validation**: Uses real-world physics to validate detection accuracy
- **On-Device Processing**: Privacy-preserving local processing without cloud dependency
- **Dual Mode Processing**: Both production and debug modes for different user needs

### User Experience Advantages
- **Zero Learning Curve**: Automated processing requires no video editing skills
- **Mobile-First Design**: Native iOS experience optimized for touch interaction
- **Instant Results**: No uploading, waiting, or subscription requirements
- **Professional Quality**: Suitable for both recreational and professional use cases

## Market Positioning

**Category:** Sports Video Analysis / Automated Video Editing  
**Price Point:** Premium one-time purchase or freemium with advanced features  
**Distribution:** iOS App Store with potential for coaching community partnerships

**Key Differentiators:**
- Volleyball-specific expertise vs generic sports apps
- Local processing vs cloud-dependent solutions  
- Automated intelligence vs manual editing tools
- Professional quality vs consumer-only focus