# TestFlight Beta Testing Guide

This guide walks you through shipping BumpSetCut to your friends via TestFlight.

## Prerequisites

- ✅ Apple Developer Account ($99/year) - [developer.apple.com](https://developer.apple.com)
- ✅ Xcode installed (you have this)
- ✅ BumpSetCut project compiles successfully
- ⚠️ Need to add new files to Xcode (StoreManager.swift, PaywallView.swift, etc.)

## Part 1: Prepare Your Xcode Project

### Step 1: Add Missing Files to Xcode

First, complete the manual step from earlier (see `ADD_FILES_TO_XCODE.md`):

1. Open `BumpSetCut.xcodeproj` in Xcode
2. Add these files:
   - `BumpSetCut/Core/Services/StoreManager.swift`
   - `BumpSetCut/Features/Settings/PaywallView.swift`
   - `BumpSetCut/Resources/Configuration.storekit`
   - `BumpSetCut/Core/Services/ModerationService.swift`
   - `BumpSetCut/Features/Social/Moderation/ReportContentSheet.swift`
   - `BumpSetCut/Features/Social/Moderation/BlockUserAlert.swift`
   - `BumpSetCut/Models/Social/ContentReport.swift`

**How to add files**:
- Right-click on the appropriate folder in Xcode
- Select "Add Files to 'BumpSetCut'..."
- Navigate to the file
- **UNCHECK** "Copy items if needed"
- **CHECK** "BumpSetCut" target
- Click "Add"

### Step 2: Configure StoreKit Testing

1. In Xcode, go to **Product → Scheme → Edit Scheme...**
2. Select **Run** → **Options** tab
3. Under **StoreKit Configuration**, select `Configuration.storekit`
4. Click **Close**

### Step 3: Update Version and Build Number

1. In Xcode, select the project (top of navigator)
2. Select the **BumpSetCut** target
3. Go to **General** tab
4. Update:
   - **Version**: `1.0` (for first release)
   - **Build**: `1` (increment each upload)

### Step 4: Configure Code Signing

1. Still in **General** tab, scroll to **Signing & Capabilities**
2. Select your **Team** (your Apple Developer account)
3. Xcode should automatically create/manage signing certificates
4. Ensure **"Automatically manage signing"** is checked

**If you see errors**:
- Make sure you're logged into Xcode with your Apple ID
- Go to **Xcode → Settings → Accounts** to add your account
- Click "Download Manual Profiles" if needed

### Step 5: Verify Build Succeeds

```bash
# Clean build folder
Product → Clean Build Folder (Cmd+Shift+K)

# Build for device
Product → Build (Cmd+B)
```

**Fix any compilation errors** before proceeding.

## Part 2: Create App in App Store Connect

### Step 1: Create App Record

1. Go to [App Store Connect](https://appstoreconnect.apple.com)
2. Click **My Apps** → **+** → **New App**
3. Fill in:
   - **Platform**: iOS
   - **Name**: BumpSetCut
   - **Primary Language**: English (U.S.)
   - **Bundle ID**: `com.yourcompany.BumpSetCut` (must match Xcode)
   - **SKU**: `bumpsetcut-ios` (can be anything unique)
   - **User Access**: Full Access

4. Click **Create**

### Step 2: Fill Required App Information

Go to **App Information** tab:

1. **App Name**: BumpSetCut
2. **Subtitle**: AI-Powered Rally Detection
3. **Privacy Policy URL**: `https://bumpsetcut.com/privacy` (must be live!)
4. **Category**:
   - Primary: Sports
   - Secondary: Photo & Video
5. **Age Rating**: Click "Edit" and answer questionnaire
   - Likely result: **12+** (due to social features)

### Step 3: Create Version Information

Go to **iOS App** → **1.0 Prepare for Submission**:

1. **What's New in This Version** (Release Notes):
   ```
   🎉 Welcome to BumpSetCut!

   • AI-powered volleyball rally detection
   • Automatic highlight extraction
   • Social features: share, like, comment
   • Free: 3 videos/week
   • Pro: Unlimited processing, no watermarks

   This is a beta version. Please report any issues!
   ```

2. **Promotional Text** (optional):
   ```
   The easiest way to find and share your best volleyball rallies
   ```

3. **Description**:
   ```
   BumpSetCut uses advanced AI to automatically detect volleyball rallies in your videos.

   FEATURES:
   • Automatic rally detection with computer vision
   • Extract individual rally highlights
   • Organize videos by beach or indoor volleyball
   • Share highlights with the community
   • Like, comment, and follow other players
   • Full-screen swipeable rally viewer

   FREE TIER:
   • Process 3 videos per week
   • 500MB file size limit
   • WiFi-only processing

   PRO SUBSCRIPTION ($7.99/month):
   • Unlimited video processing
   • Process on cellular data
   • No watermarks on exports
   • Unlimited file sizes

   Perfect for volleyball players, coaches, and fans who want to analyze and share their best plays!
   ```

4. **Keywords** (separated by commas):
   ```
   volleyball,rally,highlights,sports,AI,detection,beach volleyball,indoor volleyball,video editor,coach,analysis
   ```

5. **Support URL**: `https://bumpsetcut.com/support` (create this page)
6. **Marketing URL**: `https://bumpsetcut.com` (optional)

### Step 4: Add Screenshots (Required for TestFlight)

You need at least:
- **6.7" Display** (iPhone 16 Pro Max) - At least 3 screenshots
- **5.5" Display** (iPhone 8 Plus) - At least 3 screenshots (can reuse scaled)

**Quick way to get screenshots**:

1. Run app in simulator:
   ```bash
   # Open in iPhone 16 Pro Max simulator
   Product → Destination → iPhone 16 Pro Max
   Product → Run (Cmd+R)
   ```

2. Navigate to key screens:
   - Home/Library view
   - Video processing screen
   - Rally playback view
   - Social feed
   - Settings/subscription

3. Take screenshots:
   - Press **Cmd+S** in simulator
   - Screenshots save to Desktop

4. Upload to App Store Connect:
   - Drag screenshots into the App Store Connect interface
   - Reorder as needed
   - Add captions (optional)

**Tip**: You can use placeholder screenshots for TestFlight and improve them later for public release.

## Part 3: Create Subscription Product (for Pro tier)

### Step 1: Set Up In-App Purchases

1. In App Store Connect, go to **Features** → **In-App Purchases**
2. Click **+** → **Auto-Renewable Subscription**
3. Create **Subscription Group**:
   - **Reference Name**: BumpSetCut Pro Subscriptions
   - **Group Number**: Can be auto-generated

### Step 2: Create Monthly Subscription

1. Click **+** in subscription group
2. Fill in:
   - **Reference Name**: BumpSetCut Pro Monthly
   - **Product ID**: `com.bumpsetcut.pro.monthly` (must match StoreManager.swift)
   - **Subscription Duration**: 1 Month
   - **Subscription Price**: Tier 10 ($7.99/month in U.S.)

3. Add **Localization** (English - U.S.):
   - **Display Name**: BumpSetCut Pro
   - **Description**: Unlimited video processing, no watermarks, and process on cellular data

4. **Review Information**:
   - Upload a screenshot showing the Pro features
   - Explain what subscribers get

5. Click **Save**

### Step 3: Submit for Review (Optional for TestFlight)

For TestFlight only, you can skip IAP review initially. But for public release:
1. Click **Submit for Review** on the subscription
2. Fill out tax/banking information (if not done)

**Note**: TestFlight users can test purchases using sandbox accounts without approved subscriptions.

## Part 4: Archive and Upload Build

### Step 1: Select Generic iOS Device

In Xcode:
1. Click on the device selector (top bar)
2. Select **Any iOS Device (arm64)** or **Any iOS Device**

**Don't select a simulator!** Archives only work for real devices.

### Step 2: Create Archive

1. Go to **Product → Archive**
2. Wait for the build to complete (may take 5-10 minutes)
3. Xcode Organizer will open automatically

**If archive fails**:
- Fix any build errors
- Check code signing is configured
- Ensure deployment target is set (iOS 17.0+)

### Step 3: Distribute to App Store Connect

In the Xcode Organizer (Archives window):

1. Select your archive
2. Click **Distribute App**
3. Select **App Store Connect**
4. Click **Next**
5. Select **Upload**
6. Choose options:
   - ✅ Include bitcode: NO (deprecated)
   - ✅ Upload your app's symbols: YES (for crash reports)
   - ✅ Manage Version and Build Number: YES (Xcode auto-increments)
7. Click **Next**
8. Select **Automatically manage signing**
9. Click **Upload**

**This will take 5-15 minutes** to process and upload.

### Step 4: Wait for Processing

1. You'll see "Upload Successful" in Xcode
2. Go to App Store Connect → **TestFlight** tab
3. Wait for "Processing" to complete (5-30 minutes)
4. You'll receive an email when it's ready

**Status indicators**:
- 🟡 Processing
- 🔴 Invalid Binary (fix issues and re-upload)
- 🟢 Ready to Test

## Part 5: Set Up TestFlight Beta Testing

### Step 1: Export Compliance

When your build finishes processing, you'll see a **Missing Compliance** warning:

1. Click on the build
2. Answer encryption questions:
   - "Does your app use encryption?" → **YES** (HTTPS counts)
   - "Does it use encryption exempt from regulations?" → **YES** (standard HTTPS)
   - "Do you use any of the following?" → **NO** (unless you added custom encryption)
3. This provides the export compliance documentation

### Step 2: Create Internal Testing Group (for you)

1. In App Store Connect, go to **TestFlight** → **Internal Testing**
2. Click **+** → **Create Group**
3. Name: "Core Team"
4. Add yourself as a tester
5. Enable automatic builds
6. Click **Create**

**You'll receive an email** with TestFlight invitation.

### Step 3: Create External Testing Group (for friends)

1. Go to **TestFlight** → **External Testing**
2. Click **+** → **Create Group**
3. Name: "Beta Testers"
4. Add build version (1.0)
5. Add testers:
   - Click **Testers** → **+**
   - Enter email addresses of your friends
   - They'll receive TestFlight invitations

**External testing requires App Review for first build**, but it's faster than full review (usually 1-2 days).

### Step 4: What's New in This Version (Beta Notes)

For each build, add test notes:

```
Build 1 - Initial Beta

What to Test:
• Video upload and processing
• Rally detection accuracy
• Social features (sharing, comments, likes)
• Subscription flow (use sandbox account)
• Performance and crashes

Known Issues:
• StoreKit purchases require sandbox account
• Some UI elements may need polish

Please report bugs via Settings → Help & Support
```

### Step 5: Submit for Beta Review (External Only)

1. Click **Submit for Review** (external testing only)
2. Fill out:
   - **Beta App Description**: Brief description of the app
   - **Feedback Email**: Your email for tester feedback
   - **Test Information**: Login credentials if needed (N/A for you)
3. Wait 1-2 days for approval

**Internal testing** does not require review and is available immediately.

## Part 6: Invite Your Friends

### Method 1: Public Link (Easiest)

1. In **TestFlight** → **External Testing** → Your group
2. Click **Enable Public Link**
3. Copy the link (looks like `https://testflight.apple.com/join/XXXXXXXX`)
4. Share via:
   - Text message
   - Email
   - Social media
   - QR code (App Store Connect generates one)

**Max 10,000 testers** per public link.

### Method 2: Direct Email Invites

1. Click **Testers** → **+**
2. Enter email addresses
3. Click **Add**
4. Each friend receives a personalized invitation email

### Method 3: Share Invitation Code

When testers download TestFlight app:
1. They open TestFlight
2. Tap **Redeem**
3. Enter the code from the public link

## Part 7: Friends Install Beta

Your friends need to:

### Step 1: Install TestFlight App

1. Download **TestFlight** from the App Store (free, by Apple)
2. Open TestFlight app
3. Sign in with Apple ID

### Step 2: Accept Invitation

**If using public link**:
1. Tap the link you sent
2. Opens TestFlight app
3. Tap **Accept**
4. Tap **Install**

**If using email invitation**:
1. Open invitation email
2. Tap **View in TestFlight**
3. Tap **Accept**
4. Tap **Install**

### Step 3: Provide Feedback

In TestFlight app:
1. Open BumpSetCut
2. Tap **Send Beta Feedback**
3. Can attach screenshots and crash logs automatically

## Part 8: Update Beta Builds

When you fix bugs or add features:

### Step 1: Increment Build Number

In Xcode:
1. Select project → Target → General
2. **Build**: Increment by 1 (e.g., `1` → `2`)
3. Keep **Version** the same (`1.0`)

### Step 2: Archive and Upload Again

Repeat Part 4 (Archive and Upload)

### Step 3: Notify Testers

1. TestFlight automatically notifies testers of new builds
2. Add detailed "What's New" notes for each build
3. Testers update within TestFlight app

## Testing Checklist

Before inviting friends, test yourself:

- [ ] App launches successfully
- [ ] Sign in with Apple works
- [ ] Video upload works
- [ ] Rally processing completes
- [ ] Social features work (posting, liking, commenting)
- [ ] Subscription paywall displays
- [ ] StoreKit sandbox purchases work
- [ ] Report/block functionality works
- [ ] Export videos works
- [ ] No crashes during basic usage

## TestFlight Limitations

Be aware:
- **90-day expiration**: Builds expire after 90 days
- **10,000 external testers max** per app
- **100 internal testers max** (App Store Connect users)
- **External testing requires review** for first build per version
- **Sandbox purchases only**: Real IAP not charged

## Create Sandbox Test Account (for IAP Testing)

To test subscriptions:

1. Go to [App Store Connect](https://appstoreconnect.apple.com)
2. **Users and Access** → **Sandbox Testers**
3. Click **+** to create test account
4. Fill in:
   - **Email**: test@example.com (fake email is fine)
   - **Password**: Strong password
   - **Country**: United States
   - Other fields as needed
5. Click **Save**

**To use sandbox account**:
1. On iPhone, go to **Settings → App Store**
2. Scroll down to **Sandbox Account**
3. Sign in with sandbox email/password
4. Now IAP purchases won't charge real money

## Troubleshooting

### "Missing Compliance" Warning
- Answer the encryption questions (see Part 5, Step 1)

### Build Stuck on "Processing"
- Wait up to 30 minutes
- Check email for "Invalid Binary" notice
- Re-upload if processing fails

### Code Signing Errors
- Ensure you're logged into Xcode with Apple ID
- Check team is selected
- Delete and regenerate certificates if needed

### TestFlight Invitation Not Received
- Check spam folder
- Verify email address is correct
- Use public link as backup

### Crashes After Upload
- Check crash logs in App Store Connect
- Use uploaded symbols for readable stack traces
- Fix and upload new build

## Next Steps After Beta

Once beta testing is successful:

1. **Gather Feedback**: Ask friends for honest feedback
2. **Fix Critical Bugs**: Address crashes and major issues
3. **Polish UI**: Based on tester feedback
4. **Test Subscriptions**: Ensure IAP works with sandbox
5. **Prepare for Release**:
   - Finalize screenshots and app description
   - Host privacy policy and terms
   - Submit for full App Store review
6. **Public Release**: Change status to "Ready for Sale"

## Resources

- [TestFlight Documentation](https://developer.apple.com/testflight/)
- [App Store Connect Guide](https://help.apple.com/app-store-connect/)
- [Code Signing Guide](https://developer.apple.com/support/code-signing/)
- [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)

---

## Quick Start Summary

1. ✅ Add missing files to Xcode project
2. ✅ Update version/build number
3. ✅ Create app in App Store Connect
4. ✅ Add screenshots (at least 3)
5. ✅ Archive and upload build (Product → Archive)
6. ✅ Wait for processing (~15 minutes)
7. ✅ Answer export compliance questions
8. ✅ Create TestFlight group
9. ✅ Invite friends via public link or email
10. ✅ Friends install via TestFlight app

**Estimated time**: 2-3 hours for first-time setup, 30 minutes for subsequent uploads.

Good luck with your beta! 🚀📱
