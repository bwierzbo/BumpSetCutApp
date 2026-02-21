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
- [ ] Keychain cleared on fresh install (no stale auth)
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
- [ ] Stats card shows processing stats (responsive to Pro status)
- [ ] Quick action buttons visible: Upload, Process, Help
- [ ] "View Library" primary CTA navigates to saved video library
- [ ] "Favorite Rallies" secondary CTA navigates to favorites grid

### 2.2 Navigation
- [ ] Settings gear icon opens settings sheet
- [ ] Help button re-opens onboarding carousel
- [ ] Upload progress overlay shows during active uploads (file name, size, status)

### 2.3 Responsive Layout
- [ ] Portrait mode renders correctly
- [ ] Landscape mode adjusts layout

---

## 3. Video Upload

### 3.1 Import Flow
- [ ] Tap "Upload" on Home → PhotosPicker opens
- [ ] Select a video → folder selection sheet appears
- [ ] Select destination folder → naming dialog appears
- [ ] Enter custom name (100 char limit) → video appears in library
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
- [ ] Grid view displays video thumbnails with duration and file size
- [ ] List view displays video rows with metadata
- [ ] Toggle between grid/list via toolbar menu
- [ ] Thumbnails load progressively (no blank grid)
- [ ] Empty state shown when no videos exist
- [ ] Search bar filters videos by name
- [ ] Pull to refresh updates the list

### 4.2 Sorting
- [ ] Sort picker in toolbar (Name / Date Created / File Size)
- [ ] Changing sort option reorders videos immediately
- [ ] Sort applies to both folders and videos

### 4.3 Filtering
- [ ] Filter chips at root level: All / Processed / Unprocessed
- [ ] Selecting a filter updates displayed videos
- [ ] Filter chips hidden when inside a folder

### 4.4 Folder Management
- [ ] Create new folder → appears in library
- [ ] Rename folder via three-dot menu or long-press context menu
- [ ] Delete folder via three-dot menu → confirmation prompt → folder removed
- [ ] Delete folder with videos → appropriate warning (videos moved to parent)
- [ ] Folders limited to one level deep (no nested subfolder creation)

### 4.5 Video Context Menu
- [ ] Long-press video → context menu with Delete, Rename, Move to Folder
- [ ] Rename video → name updates in grid/list
- [ ] Move video to folder → video moves, counts update
- [ ] Drag-drop video onto folder → video moves

### 4.6 Processed Games Library
- [ ] Only processed videos appear here
- [ ] Tap a processed video → opens rally player
- [ ] Unprocessed videos do NOT appear in processed library

### 4.7 Navigation
- [ ] Back chevron button returns to parent folder
- [ ] Swipe-right gesture returns to parent folder
- [ ] Navigation title updates to show current folder name

---

## 5. Favorite Rallies

### 5.1 Grid Display
- [ ] Navigate to Favorites from Home → FavoritesGridView loads
- [ ] 3-column thumbnail grid with duration badges
- [ ] Empty state shown when no favorites exist
- [ ] Rally count label displayed in header

### 5.2 Sorting
- [ ] Sort picker in toolbar (Name / Date Created / File Size)
- [ ] Changing sort reorders both folders and videos

### 5.3 Folder Management
- [ ] Create folder via toolbar button → sheet with name input
- [ ] Folders display in 2-column grid style
- [ ] Rename folder via three-dot menu or long-press
- [ ] Delete folder via three-dot menu → confirmation prompt
- [ ] Drag-drop video onto folder to move

### 5.4 Video Context Menu
- [ ] Long-press thumbnail → Rename, Move to Folder, Remove Favorite
- [ ] Rename → alert with text field pre-filled → name updates
- [ ] Move to Folder → picker sheet with available folders
- [ ] Remove Favorite → confirmation → unfavorites and syncs back to source video

### 5.5 Favorites Feed (Full-Screen)
- [ ] Tap thumbnail → full-screen vertical feed opens
- [ ] TikTok-style vertical swipe between favorites
- [ ] Counter shows current position (e.g., "3/12")
- [ ] Video name displayed at bottom
- [ ] Close button (X) dismisses feed

### 5.6 Tap-to-Pause
- [ ] Tap video in feed → playback pauses
- [ ] Centered play icon overlay appears when paused
- [ ] Tap again → resumes playback, icon disappears

### 5.7 Long-Press Trim in Feed
- [ ] Long-press (0.5s) on video → trim mode activates
- [ ] Filmstrip with thumbnails appears at bottom
- [ ] Drag left handle → trims start of clip
- [ ] Drag right handle → trims end of clip
- [ ] Duration label updates in real-time
- [ ] Scrubbing handles seeks video to match
- [ ] "Done" → saves trim, playback loops within trimmed bounds
- [ ] "Cancel" → reverts to previous trim values
- [ ] Trim persists across app restarts (MetadataStore sidecar JSON)
- [ ] Scroll to different favorite and back → trim still applied

### 5.8 Looping with Trim
- [ ] Untrimmed clip → loops from start to end
- [ ] Trimmed clip → loops within trimmed boundaries only
- [ ] Boundary observer resets playback at trim end point

---

## 6. Video Processing (Critical Path)

### 6.1 Start Processing
- [ ] Tap "Process" on Home → list of unprocessed videos shown
- [ ] Select a video → ProcessVideoView opens
- [ ] Video metadata displayed (duration, resolution, file size)
- [ ] Volleyball type selection available (Beach/Indoor)
- [ ] "Process Video" button is tappable

### 6.2 Processing Progress
- [ ] Tap "Process Video" → animated brain icon appears
- [ ] Progress bar increments smoothly from 0% to 100%
- [ ] "Analyzing video..." label shown during processing
- [ ] Floating progress pill visible above tab bar during processing
- [ ] "Keep app open" warning displayed
- [ ] App remains responsive during processing (UI not frozen)
- [ ] Backgrounding the app during processing → processing continues (~30s grace)

### 6.3 Processing Results - Rallies Found
- [ ] Rally count displayed (e.g., "12 rallies detected")
- [ ] Total duration and time saved percentage shown
- [ ] "Preview" button → opens rally player
- [ ] "Save" button → folder selection → saves processed video
- [ ] Processed video appears in Processed Games library
- [ ] Original video now shows as "already processed" (cannot reprocess)

### 6.4 Processing Results - No Rallies
- [ ] "No rallies detected" message shown
- [ ] Retry option available
- [ ] Dismiss returns to library without crash

### 6.5 Processing Edge Cases
- [ ] Process a 10-second video (very short) → handles gracefully
- [ ] Process a 30+ minute video → completes (may take time)
- [ ] Process a non-volleyball video → "no rallies" result (no crash)
- [ ] Storage nearly full → low storage warning shown
- [ ] Kill app during processing → no corrupt metadata on relaunch
- [ ] Already-processed video → "already processed" state, no reprocess button

### 6.6 Thorough vs Quick Mode
- [ ] Settings → toggle "Thorough Analysis" OFF
- [ ] Process a video → completes faster (fewer frames analyzed)
- [ ] Toggle back ON → more detailed processing

---

## 7. Rally Playback (Critical Path)

### 7.1 Basic Playback
- [ ] Open processed video → rally player loads
- [ ] First rally plays automatically
- [ ] Video plays with correct orientation (portrait/landscape)
- [ ] Play/pause works correctly
- [ ] Rally counter visible (e.g., "Rally 3 of 12")

### 7.2 Navigation Between Rallies
- [ ] Swipe up → next rally loads and plays
- [ ] Swipe down → previous rally loads and plays
- [ ] Rapid swiping → no crash, smooth transitions
- [ ] First rally → swipe down does nothing (or bounces)
- [ ] Last rally → swipe up does nothing (or bounces)
- [ ] No audio bleed between rallies during fast swiping

### 7.3 Rally Selection (Save/Remove)
- [ ] Tap to toggle rally as "saved" → visual indicator updates
- [ ] Tap again to deselect → indicator clears
- [ ] Counter pill shows count of selected rallies
- [ ] Removing all rallies → appropriate empty state
- [ ] Favoriting a rally → clip appears in Favorite Rallies

### 7.4 Per-Rally Trim/Buffer
- [ ] Long-press on rally → trim mode activates with filmstrip
- [ ] Drag left handle to adjust start boundary (up to ±3s)
- [ ] Drag right handle to adjust end boundary (up to ±3s)
- [ ] Duration label updates in real-time
- [ ] Trim values persist when navigating away and back
- [ ] Trim values persist across app restarts (sidecar JSON)
- [ ] Trim does not extend beyond original video boundaries

### 7.5 Rally Overview Sheet
- [ ] Tap counter pill → overview sheet opens
- [ ] Thumbnail grid shows all rallies
- [ ] Tap a thumbnail → jumps to that rally in player
- [ ] Selected/deselected rallies visually distinguished
- [ ] Can select/deselect rallies from overview
- [ ] Export from overview works
- [ ] Close sheet → returns to current rally position

### 7.6 Undo
- [ ] Make several actions (save, remove, trim) → undo reverts last action
- [ ] Multiple undos work (multi-level undo stack)
- [ ] Undo after trim → trim values revert

### 7.7 Player Cache
- [ ] Play through 10+ rallies → no memory warning
- [ ] Navigate back to earlier rally → loads from cache or re-creates player
- [ ] No audio from off-screen rallies
- [ ] Sliding window keeps max 5 players (current ±2)

### 7.8 Gesture Tips
- [ ] First time viewing rallies → gesture tips overlay appears
- [ ] Tips do not reappear on subsequent views

---

## 8. Export

### 8.1 Save to Device
- [ ] From rally player → tap export button
- [ ] Folder selection appears
- [ ] Select folder → rally clips exported as MP4
- [ ] Exported clips play correctly in Photos app
- [ ] Video orientation preserved in export
- [ ] Audio preserved in export

### 8.2 Watermark
- [ ] Free tier → exported clips have watermark overlay
- [ ] Pro tier → no watermark on exports

### 8.3 Batch Export
- [ ] Select multiple rallies → export all selected
- [ ] Export from overview sheet works
- [ ] Each clip is a separate file with correct time boundaries

### 8.4 Export Edge Cases
- [ ] Export a trimmed rally → trim offsets applied correctly
- [ ] Export with storage nearly full → appropriate error
- [ ] Cancel export mid-way → no corrupt partial files

---

## 9. Authentication (Social Gate)

### 9.1 Apple Sign-In
- [ ] Tap Feed or Profile tab (unauthenticated) → AuthGate appears
- [ ] "Sign in with Apple" button → Apple auth sheet appears
- [ ] Complete Apple auth → authenticated state reached
- [ ] User profile created/restored
- [ ] If first sign-in → username picker modal appears
- [ ] Enter valid username → profile complete, gate dismissed

### 9.2 Session Persistence
- [ ] Kill and relaunch app → still authenticated (no re-login)
- [ ] Keychain cleared on reinstall → fresh auth state
- [ ] Session expires → re-auth prompt appears (not crash)
- [ ] Sign out from Settings → returns to unauthenticated state

### 9.3 Continue Without Account
- [ ] "Continue without account" option visible on AuthGate
- [ ] Selecting it → dismisses auth gate
- [ ] Social features (like, comment, share) still gated when attempted

---

## 10. Social Feed

### 10.1 Feed Display
- [ ] Feed tab (authenticated) → highlights load
- [ ] TikTok-style vertical scroll with snap-to-page
- [ ] Each card: full-screen video, author info, like/comment buttons, caption
- [ ] "For You" and "Following" tabs work
- [ ] Switching tabs reloads appropriate content
- [ ] Empty "Following" feed → shows "follow users" prompt

### 10.2 Feed Interactions
- [ ] Tap heart (or double-tap video) → like toggles instantly (optimistic)
- [ ] Like count increments/decrements immediately
- [ ] Tap comment button → CommentsSheet opens
- [ ] Tap author avatar/name → ProfileView opens
- [ ] Scroll to bottom → more highlights load (pagination)

### 10.3 Polls on Highlights
- [ ] Poll overlay displays on highlight cards that have polls
- [ ] Pre-vote: tappable option buttons shown
- [ ] Tap an option → vote registered, results shown with percentage bars
- [ ] Post-vote: results visible with vote count
- [ ] Only authenticated users can vote
- [ ] Author sees results immediately

### 10.4 Feed Edge Cases
- [ ] No internet → appropriate offline message
- [ ] Slow connection → loading state visible, no crash
- [ ] Pull to refresh → feed reloads
- [ ] Delete own highlight from feed → removed immediately

---

## 11. Sharing to Community

### 11.1 Share Flow
- [ ] From rally player → tap "Share" button
- [ ] ShareRallySheet opens with rally preview
- [ ] Caption editor accepts text + hashtags
- [ ] Visibility options available (Public / Private / Friends Only)
- [ ] Tap "Post" → upload progress shown (uploading → processing → complete)
- [ ] On success → highlight appears in feed

### 11.2 Batch Share
- [ ] "Post All" option for multiple rallies
- [ ] Each rally uploaded sequentially with progress
- [ ] All appear in feed on completion

### 11.3 Share Failures
- [ ] No internet during upload → error state with retry button
- [ ] Retry after reconnecting → upload resumes/restarts
- [ ] Cancel upload → cleanup, no partial post

---

## 12. Comments

- [ ] Tap comment button on highlight → CommentsSheet opens
- [ ] Existing comments load with avatar, username, timestamp
- [ ] Type comment + submit → appears in list immediately
- [ ] Delete own comment → removed from list
- [ ] Comment on highlight with no comments → first comment appears
- [ ] Close and reopen comments → persisted (not lost)

---

## 13. User Profile

### 13.1 Own Profile
- [ ] Profile tab → shows own profile
- [ ] Avatar, display name, username, bio visible
- [ ] Stats: highlight count, following, followers
- [ ] Highlight grid shows own posts
- [ ] Tap own highlight → plays in viewer
- [ ] "Edit Profile" → EditProfileView opens
- [ ] Update bio/display name → changes saved and reflected

### 13.2 Other User Profiles
- [ ] Tap author in feed → their profile opens
- [ ] Follow button visible → tap to follow
- [ ] Followers count increments on their profile
- [ ] Following count increments on own profile
- [ ] Unfollow → counts decrement
- [ ] View their highlights grid
- [ ] Tap a highlight → plays in viewer

### 13.3 Followers/Following Lists
- [ ] Tap followers count → FollowListView opens
- [ ] Tap following count → FollowListView opens
- [ ] Lists show avatars, usernames
- [ ] Tap a user → navigates to their profile

### 13.4 Community Search
- [ ] Search tab → search bar visible
- [ ] Type username → matching users appear
- [ ] Tap user → ProfileView opens
- [ ] Empty search → suggestions or empty state

---

## 14. Settings

### 14.1 Subscription
- [ ] Free tier: shows weekly processing credits, max video size (500MB), WiFi requirement, watermark status
- [ ] Pro tier: shows Pro badge, unlimited processing, no watermark
- [ ] "Upgrade to Pro" button → PaywallView opens
- [ ] "Restore Purchases" works (for TestFlight testers with prior purchase)

### 14.2 Appearance
- [ ] Theme picker: Dark / Light / System with preview boxes
- [ ] Selecting a theme → changes immediately

### 14.3 Processing
- [ ] "Thorough Analysis" toggle → persists across restart

### 14.4 Privacy
- [ ] "Analytics" toggle for anonymous usage data

### 14.5 Account Management (authenticated)
- [ ] User account info displayed
- [ ] "Sign Out" → returns to unauthenticated state, clears session
- [ ] "Delete Account" → confirmation dialog → account deleted
- [ ] After deletion → returned to unauthenticated state

### 14.6 Legal
- [ ] Privacy policy link opens
- [ ] Terms of service link opens
- [ ] Community guidelines link opens

### 14.7 About
- [ ] App version and build number displayed

### 14.8 Content Moderation
- [ ] Report content option available on other users' highlights
- [ ] Report flow: select reason → submit
- [ ] Block user option available
- [ ] Blocked user's content no longer appears in feed

---

## 15. Stability & Performance

### 15.1 Memory
- [ ] Process a long video (15+ min) → no memory crash
- [ ] Scroll through 50+ rally cards → memory stable
- [ ] Browse feed with 20+ highlights → no memory warning
- [ ] Background the app during playback → no crash on return
- [ ] Favorites feed with 20+ clips → sliding-window cache stable

### 15.2 App Lifecycle
- [ ] Background → foreground: state preserved (current screen, playback position)
- [ ] Kill app → relaunch: library intact, settings intact, auth intact
- [ ] Receive phone call during processing → processing paused/resumed gracefully
- [ ] Low battery mode → app still functional

### 15.3 Orientation
- [ ] Portrait video plays in portrait (`.fit`)
- [ ] Landscape video plays in landscape (`.fill`)
- [ ] Rotate device during playback → layout adjusts
- [ ] Export preserves original orientation

### 15.4 Empty States
- [ ] No videos uploaded → library empty state (not blank/crash)
- [ ] No rallies detected → appropriate message
- [ ] No favorites → empty state with prompt in FavoritesGridView
- [ ] No highlights in feed → empty state with prompt
- [ ] No followers/following → "0" counts, no crash
- [ ] No comments on highlight → empty list, input bar still visible

### 15.5 Network Conditions
- [ ] Process video with no internet → works (local operation)
- [ ] Social features with no internet → offline message, queued actions
- [ ] Restore internet → OfflineQueue drains, pending actions complete
- [ ] Slow/flaky connection → loading states visible, no infinite spinners

---

## 16. Data Integrity

### 16.1 Persistence
- [ ] Upload video → kill app → relaunch → video still in library
- [ ] Process video → kill app → relaunch → processing metadata intact
- [ ] Trim a rally → kill app → relaunch → trim values preserved
- [ ] Trim a favorite clip → kill app → relaunch → trim values preserved
- [ ] Save rally selections → kill app → relaunch → selections preserved
- [ ] Favorite a rally → kill app → relaunch → appears in Favorites
- [ ] Settings changes → kill app → relaunch → settings intact

### 16.2 Metadata
- [ ] Processed video shows correct rally count on reopen
- [ ] Original video correctly linked to processed output
- [ ] Deleting original video → processed video still accessible
- [ ] Deleting processed video → original video can be reprocessed
- [ ] Removing favorite syncs unfavorite back to source video's review selections

---

## 17. Quick Smoke Test (5-Minute Walkthrough)

Run this end-to-end before every beta build:

1. [ ] Fresh launch → Home screen loads
2. [ ] Upload a volleyball video from Photos
3. [ ] Process the video → see rally results
4. [ ] Preview rallies → swipe through 3+ rallies
5. [ ] Long-press to trim one rally
6. [ ] Favorite a rally → check it appears in Favorite Rallies
7. [ ] Open Favorites → tap clip → tap to pause/resume
8. [ ] Long-press in favorites feed → trim a clip → confirm
9. [ ] Save selected rallies to a folder
10. [ ] Sign in with Apple
11. [ ] Share a rally to the feed
12. [ ] View it in the social feed
13. [ ] Like and comment on it
14. [ ] Vote on a poll (if available)
15. [ ] Check Settings → sign out
16. [ ] Relaunch app → library and favorites still intact

---

## Notes

- **Devices to test**: iPhone 15/16 Pro (primary), iPhone SE (smallest screen), iPad (if supported)
- **iOS versions**: iOS 18+ (minimum deployment target)
- **Network conditions**: WiFi, cellular, airplane mode
- **Storage**: Test with <1GB free space to trigger warnings
