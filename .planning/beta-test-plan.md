# BumpSetCut Beta Test Plan

## How to Use This Plan
- Work through each section in order (Core first, then Social)
- Mark each test `[x]` as you verify it
- Note any bugs inline with `BUG:` prefix
- Note any UX concerns with `UX:` prefix

---

## 1. First Launch & Onboarding

### 1.1 Fresh Install
- [ ] App launches without crash on clean install
- [ ] Onboarding carousel appears automatically
- [ ] All 4 pages display correctly (Upload, AI Detection, Save Rallies, Share & Connect)
- [ ] "Skip" button works on pages 1-3
- [ ] "Done" on last page dismisses onboarding
- [ ] Onboarding does NOT reappear after completion
- [ ] Main tab bar shows 4 tabs: Home, Feed, Search, Profile

### 1.2 Permissions
- [ ] Photo library permission prompt appears on first upload attempt
- [ ] Denying permission shows appropriate fallback (no crash)
- [ ] Granting permission allows video selection

---

## 2. Home Screen

### 2.1 Layout & Display
- [ ] Hero section renders with app branding
- [ ] Stats card shows: Total Rallies, Processed Videos, Tier status
- [ ] Quick action buttons visible: Upload, Process, Help

### 2.2 Navigation
- [ ] "View Saved Games" navigates to saved video library
- [ ] "View Processed Games" navigates to processed library
- [ ] Settings gear icon opens settings sheet
- [ ] Help button re-opens onboarding carousel

---

## 3. Video Upload

### 3.1 Import Flow
- [ ] Tap "Upload" on Home → PhotosPicker opens
- [ ] Select a video → folder selection sheet appears
- [ ] Select destination folder → naming dialog appears
- [ ] Enter custom name → video appears in library
- [ ] Skip naming (use default) → video appears with auto-generated name
- [ ] Cancel at any step → no partial files left behind

### 3.2 Large File Handling
- [ ] Upload a video >500MB on free tier → storage/tier warning shown
- [ ] Upload a 5-minute video → completes without memory crash
- [ ] Upload a 30+ minute video → completes (URL-based, no Data loading)

### 3.3 Edge Cases
- [ ] Upload portrait video → orientation metadata preserved
- [ ] Upload landscape video → orientation metadata preserved
- [ ] Upload same video twice → handled gracefully (no duplicate crash)
- [ ] Upload with no folders → default folder used or creation prompted

---

## 4. Video Library

### 4.1 Saved Games Library
- [ ] Grid displays video thumbnails with duration and file size
- [ ] Thumbnails load progressively (no blank grid)
- [ ] Empty state shown when no videos exist
- [ ] Search bar filters videos by name
- [ ] Pull to refresh updates the list

### 4.2 Folder Management
- [ ] Create new folder → appears in library
- [ ] Rename folder → name updates everywhere
- [ ] Delete folder → confirmation prompt → folder removed
- [ ] Delete folder with videos → appropriate warning

### 4.3 Processed Games Library
- [ ] Only processed videos appear here
- [ ] Tap a processed video → opens rally player
- [ ] Unprocessed videos do NOT appear in processed library

### 4.4 Navigation Between Libraries
- [ ] "Saved Games" and "Processed Games" are clearly distinguished
- [ ] Breadcrumb navigation works for nested folders
- [ ] Back button returns to parent folder

---

## 5. Video Processing (Critical Path)

### 5.1 Start Processing
- [ ] Tap "Process" on Home → list of unprocessed videos shown
- [ ] Select a video → ProcessVideoView opens
- [ ] Video metadata displayed (duration, resolution, file size)
- [ ] Volleyball type selection available (Beach/Indoor)
- [ ] "Process Video" button is tappable

### 5.2 Processing Progress
- [ ] Tap "Process Video" → animated brain icon appears
- [ ] Progress bar increments smoothly from 0% to 100%
- [ ] "Analyzing video..." label shown during processing
- [ ] App remains responsive during processing (UI not frozen)
- [ ] Backgrounding the app during processing → processing continues (~30s grace)

### 5.3 Processing Results - Rallies Found
- [ ] Rally count displayed (e.g., "12 rallies detected")
- [ ] Total duration and time saved percentage shown
- [ ] "Preview" button → opens rally player
- [ ] "Save" button → folder selection → saves processed video
- [ ] Processed video appears in Processed Games library
- [ ] Original video now shows as "already processed" (cannot reprocess)

### 5.4 Processing Results - No Rallies
- [ ] "No rallies detected" message shown
- [ ] Retry option available
- [ ] Dismiss returns to library without crash

### 5.5 Processing Edge Cases
- [ ] Process a 10-second video (very short) → handles gracefully
- [ ] Process a 30+ minute video → completes (may take time)
- [ ] Process a non-volleyball video → "no rallies" result (no crash)
- [ ] Storage nearly full → warning before processing starts
- [ ] Kill app during processing → no corrupt metadata on relaunch
- [ ] Already-processed video → "already processed" state, no reprocess button

### 5.6 Thorough vs Quick Mode
- [ ] Settings → toggle "Thorough Analysis" OFF
- [ ] Process a video → completes faster (fewer frames analyzed)
- [ ] Toggle back ON → more detailed processing

---

## 6. Rally Playback (Critical Path)

### 6.1 Basic Playback
- [ ] Open processed video → rally player loads
- [ ] First rally plays automatically
- [ ] Video plays with correct orientation (portrait/landscape)
- [ ] Play/pause works correctly
- [ ] Rally counter visible (e.g., "Rally 3 of 12")

### 6.2 Navigation Between Rallies
- [ ] Swipe up → next rally loads and plays
- [ ] Swipe down → previous rally loads and plays
- [ ] Rapid swiping → no crash, smooth transitions
- [ ] First rally → swipe down does nothing (or bounces)
- [ ] Last rally → swipe up does nothing (or bounces)
- [ ] No audio bleed between rallies during fast swiping

### 6.3 Rally Selection (Save/Remove)
- [ ] Tap to toggle rally as "saved" → visual indicator updates
- [ ] Tap again to deselect → indicator clears
- [ ] Counter pill shows count of selected rallies
- [ ] Removing all rallies → appropriate empty state

### 6.4 Per-Rally Trim/Buffer
- [ ] Long-press on rally → trim mode activates
- [ ] Adjust start buffer (- button): decreases in 0.5s steps, down to -3s
- [ ] Adjust start buffer (+ button): increases in 0.5s steps, up to +3s
- [ ] Adjust end buffer similarly
- [ ] Trim values persist when navigating away and back
- [ ] Trim values persist across app restarts (sidecar JSON)
- [ ] Trim does not extend beyond original video boundaries

### 6.5 Rally Overview Sheet
- [ ] Tap counter pill → overview sheet opens
- [ ] Thumbnail grid shows all rallies
- [ ] Tap a thumbnail → jumps to that rally in player
- [ ] Selected/deselected rallies visually distinguished
- [ ] Can select/deselect rallies from overview
- [ ] Close sheet → returns to current rally position

### 6.6 Undo
- [ ] Make several actions (save, remove, trim) → undo reverts last action
- [ ] Multiple undos work (multi-level undo stack)
- [ ] Undo after trim → trim values revert

### 6.7 Player Cache
- [ ] Play through 10+ rallies → no memory warning
- [ ] Navigate back to earlier rally → loads from cache or re-creates player
- [ ] No audio from off-screen rallies

### 6.8 Gesture Tips
- [ ] First time viewing rallies → gesture tips overlay appears
- [ ] Tips do not reappear on subsequent views

---

## 7. Export

### 7.1 Save to Device
- [ ] From rally player → tap "Save" or export button
- [ ] Folder selection appears
- [ ] Select folder → rally clips exported as MP4
- [ ] Exported clips play correctly in Photos app
- [ ] Video orientation preserved in export
- [ ] Audio preserved in export

### 7.2 Batch Export
- [ ] Select multiple rallies → export all selected
- [ ] Export from overview sheet works
- [ ] Each clip is a separate file with correct time boundaries

### 7.3 Export Edge Cases
- [ ] Export a trimmed rally → trim offsets applied correctly
- [ ] Export with storage nearly full → appropriate error
- [ ] Cancel export mid-way → no corrupt partial files

---

## 8. Authentication (Social Gate)

### 8.1 Apple Sign-In
- [ ] Tap Feed or Profile tab (unauthenticated) → AuthGate appears
- [ ] "Sign in with Apple" button → Apple auth sheet appears
- [ ] Complete Apple auth → authenticated state reached
- [ ] User profile created/restored
- [ ] If first sign-in → username picker modal appears
- [ ] Enter valid username → profile complete, gate dismissed

### 8.2 Email Sign-In
- [ ] Toggle to "Sign Up" form
- [ ] Enter email + password → account created
- [ ] Toggle to "Sign In" → existing account logs in
- [ ] Invalid email format → form validation error shown
- [ ] Wrong password → error message shown
- [ ] "Forgot Password" link → ForgotPasswordView opens
- [ ] Password reset flow works end-to-end

### 8.3 Session Persistence
- [ ] Kill and relaunch app → still authenticated (no re-login)
- [ ] Session expires → re-auth prompt appears (not crash)
- [ ] Sign out from Settings → returns to unauthenticated state

### 8.4 Continue Without Account
- [ ] "Continue without account" option visible on AuthGate
- [ ] Selecting it → dismisses auth gate
- [ ] Social features (like, comment, share) still gated when attempted

---

## 9. Social Feed

### 9.1 Feed Display
- [ ] Feed tab (authenticated) → highlights load
- [ ] TikTok-style vertical scroll with snap-to-page
- [ ] Each card: full-screen video, author info, like/comment buttons, caption
- [ ] "For You" and "Following" tabs work
- [ ] Switching tabs reloads appropriate content
- [ ] Empty "Following" feed → shows "follow users" prompt

### 9.2 Feed Interactions
- [ ] Tap heart (or double-tap video) → like toggles instantly (optimistic)
- [ ] Like count increments/decrements immediately
- [ ] Tap comment button → CommentsSheet opens
- [ ] Tap author avatar/name → ProfileView opens
- [ ] Scroll to bottom → more highlights load (pagination)

### 9.3 Feed Edge Cases
- [ ] No internet → appropriate offline message
- [ ] Slow connection → loading state visible, no crash
- [ ] Pull to refresh → feed reloads
- [ ] Delete own highlight from feed → removed immediately

---

## 10. Sharing to Community

### 10.1 Share Flow
- [ ] From rally player → tap "Share" button
- [ ] ShareRallySheet opens with rally preview
- [ ] Caption editor accepts text + hashtags
- [ ] "Hide likes" toggle works
- [ ] Tap "Post" → upload progress shown (uploading → processing → complete)
- [ ] On success → highlight appears in feed

### 10.2 Batch Share
- [ ] "Post All" option for multiple rallies
- [ ] Each rally uploaded sequentially with progress
- [ ] All appear in feed on completion

### 10.3 Share Failures
- [ ] No internet during upload → error state with retry button
- [ ] Retry after reconnecting → upload resumes/restarts
- [ ] Cancel upload → cleanup, no partial post
- [ ] Rally exceeds duration limit (>1 min) → validation error before upload

---

## 11. Comments

- [ ] Tap comment button on highlight → CommentsSheet opens
- [ ] Existing comments load with avatar, username, timestamp
- [ ] Type comment + submit → appears in list immediately
- [ ] Delete own comment → removed from list
- [ ] Comment on highlight with no comments → first comment appears
- [ ] Close and reopen comments → persisted (not lost)

---

## 12. User Profile

### 12.1 Own Profile
- [ ] Profile tab → shows own profile
- [ ] Avatar, display name, username, bio visible
- [ ] Stats: highlight count, following, followers
- [ ] Highlight grid shows own posts
- [ ] "Edit Profile" → EditProfileView opens
- [ ] Update bio/display name → changes saved and reflected

### 12.2 Other User Profiles
- [ ] Tap author in feed → their profile opens
- [ ] Follow button visible → tap to follow
- [ ] Followers count increments on their profile
- [ ] Following count increments on own profile
- [ ] Unfollow → counts decrement
- [ ] View their highlights grid
- [ ] Tap a highlight → plays in viewer

### 12.3 Community Search
- [ ] Search tab → search bar visible
- [ ] Type username → matching users appear
- [ ] Tap user → ProfileView opens
- [ ] Empty search → suggestions or empty state

---

## 13. Settings

### 13.1 Core Settings
- [ ] Appearance: System / Light / Dark → theme changes immediately
- [ ] Thorough Analysis toggle → persists across restart
- [ ] App version and build number displayed

### 13.2 Subscription
- [ ] Free tier: shows processing limit (3/week), max video size (500MB)
- [ ] Subscription button → PaywallView opens
- [ ] Feature list displays correctly
- [ ] "Restore Purchases" works (for TestFlight testers with prior purchase)

### 13.3 Account Management
- [ ] "Sign Out" → returns to unauthenticated state, clears session
- [ ] "Delete Account" → confirmation dialog → account deleted
- [ ] After deletion → returned to unauthenticated state

### 13.4 Privacy & Legal
- [ ] Privacy policy link opens
- [ ] Terms of service link opens
- [ ] Community guidelines link opens
- [ ] "Hide Profile" toggle → profile hidden from search

### 13.5 Content Moderation
- [ ] Report content option available on other users' highlights
- [ ] Report flow: select reason → submit
- [ ] Block user option available
- [ ] Blocked user's content no longer appears in feed

---

## 14. Stability & Performance

### 14.1 Memory
- [ ] Process a long video (15+ min) → no memory crash
- [ ] Scroll through 50+ rally cards → memory stable
- [ ] Browse feed with 20+ highlights → no memory warning
- [ ] Background the app during playback → no crash on return

### 14.2 App Lifecycle
- [ ] Background → foreground: state preserved (current screen, playback position)
- [ ] Kill app → relaunch: library intact, settings intact, auth intact
- [ ] Receive phone call during processing → processing paused/resumed gracefully
- [ ] Low battery mode → app still functional

### 14.3 Orientation
- [ ] Portrait video plays in portrait (`.fit`)
- [ ] Landscape video plays in landscape (`.fill`)
- [ ] Rotate device during playback → layout adjusts
- [ ] Export preserves original orientation

### 14.4 Empty States
- [ ] No videos uploaded → library empty state (not blank/crash)
- [ ] No rallies detected → appropriate message
- [ ] No highlights in feed → empty state with prompt
- [ ] No followers/following → "0" counts, no crash
- [ ] No comments on highlight → empty list, input bar still visible

### 14.5 Network Conditions
- [ ] Process video with no internet → works (local operation)
- [ ] Social features with no internet → offline message, queued actions
- [ ] Restore internet → OfflineQueue drains, pending actions complete
- [ ] Slow/flaky connection → loading states visible, no infinite spinners

---

## 15. Data Integrity

### 15.1 Persistence
- [ ] Upload video → kill app → relaunch → video still in library
- [ ] Process video → kill app → relaunch → processing metadata intact
- [ ] Trim a rally → kill app → relaunch → trim values preserved
- [ ] Save rally selections → kill app → relaunch → selections preserved
- [ ] Settings changes → kill app → relaunch → settings intact

### 15.2 Metadata
- [ ] Processed video shows correct rally count on reopen
- [ ] Original video correctly linked to processed output
- [ ] Deleting original video → processed video still accessible
- [ ] Deleting processed video → original video can be reprocessed

---

## 16. Quick Smoke Test (5-Minute Walkthrough)

Run this end-to-end before every beta build:

1. [ ] Fresh launch → Home screen loads
2. [ ] Upload a volleyball video from Photos
3. [ ] Process the video → see rally results
4. [ ] Preview rallies → swipe through 3+ rallies
5. [ ] Long-press to trim one rally
6. [ ] Save selected rallies to a folder
7. [ ] Sign in with Apple
8. [ ] Share a rally to the feed
9. [ ] View it in the social feed
10. [ ] Like and comment on it
11. [ ] Check Settings → sign out
12. [ ] Relaunch app → library still intact

---

## Notes

- **Devices to test**: iPhone 15/16 Pro (primary), iPhone SE (smallest screen), iPad (if supported)
- **iOS versions**: iOS 17+ (minimum deployment target)
- **Network conditions**: WiFi, cellular, airplane mode
- **Storage**: Test with <1GB free space to trigger warnings
