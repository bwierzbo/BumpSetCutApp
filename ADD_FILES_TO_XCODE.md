# Adding New Files to Xcode Project

## Files to Add

The following files were created but need to be added to the Xcode project:

1. **BumpSetCut/Core/Services/StoreManager.swift** - StoreKit 2 manager
2. **BumpSetCut/Features/Settings/PaywallView.swift** - Subscription paywall UI
3. **BumpSetCut/Resources/Configuration.storekit** - StoreKit testing configuration

## Step-by-Step Instructions

### 1. Add StoreManager.swift

1. In Xcode's Project Navigator (left sidebar), expand the folder tree:
   - `BumpSetCut` → `Core` → `Services`
2. Right-click on the **Services** folder
3. Select **"Add Files to 'BumpSetCut'..."**
4. Navigate to: `BumpSetCut/Core/Services/StoreManager.swift`
5. **IMPORTANT**: Uncheck "Copy items if needed" (file is already in correct location)
6. **IMPORTANT**: Check that "BumpSetCut" target is selected
7. Click **Add**

### 2. Add PaywallView.swift

1. In Project Navigator, expand: `BumpSetCut` → `Features` → `Settings`
2. Right-click on the **Settings** folder
3. Select **"Add Files to 'BumpSetCut'..."**
4. Navigate to: `BumpSetCut/Features/Settings/PaywallView.swift`
5. **IMPORTANT**: Uncheck "Copy items if needed"
6. **IMPORTANT**: Check that "BumpSetCut" target is selected
7. Click **Add**

### 3. Add Configuration.storekit

1. In Project Navigator, expand: `BumpSetCut` → `Resources`
   - If no Resources folder exists, right-click `BumpSetCut` root and add it there
2. Right-click on the **Resources** folder (or project root)
3. Select **"Add Files to 'BumpSetCut'..."**
4. Navigate to: `BumpSetCut/Resources/Configuration.storekit`
5. **IMPORTANT**: Uncheck "Copy items if needed"
6. **DO NOT** check any target (StoreKit config files don't belong to targets)
7. Click **Add**

### 4. Configure StoreKit Testing

1. Click on the project name **"BumpSetCut"** at the top of Project Navigator
2. In the toolbar, click on the scheme selector (says "BumpSetCut > ...") → **Edit Scheme...**
3. In the left sidebar, select **Run** → **Options** tab
4. Find the **"StoreKit Configuration"** dropdown
5. Select **"Configuration.storekit"**
6. Click **Close**

### 5. Verify Build

1. Press **Cmd+B** to build the project
2. Check for any compilation errors in the Issues Navigator (⚠️ icon)
3. Common issues:
   - Missing imports: Add `import StoreKit` if needed
   - Type not found: Ensure files are added to correct target

### 6. Test StoreKit Integration

1. Run the app in simulator (Cmd+R)
2. Go to Settings
3. Check that subscription section appears
4. Tap "Upgrade to Pro" to open paywall
5. Verify products load from Configuration.storekit

## After Adding Files

Once files are successfully added:

1. **Build the project** (Cmd+B) to ensure no errors
2. **Commit the changes**:
   ```bash
   git add BumpSetCut.xcodeproj/project.pbxproj
   git commit -m "chore: add StoreKit files to Xcode project"
   ```

## Troubleshooting

### Files appear in red in Xcode
- The files don't exist at expected path
- Right-click → "Show in Finder" to verify location

### "No such module 'StoreKit'" error
- StoreKit is built-in, ensure deployment target is iOS 15.0+
- Check project → Build Settings → iOS Deployment Target

### StoreKit Configuration not appearing in scheme
- Ensure Configuration.storekit was added to project (not just target)
- Try closing and reopening Xcode

### Build errors with @Observable
- Ensure iOS deployment target is 17.0+ (for @Observable macro)
- Or change @Observable to @ObservableObject (iOS 13+)

## Next Steps After Files Added

1. ✅ Build succeeds
2. ✅ Test subscription flow in simulator
3. ✅ Create subscription in App Store Connect
4. ✅ Test with real StoreKit sandbox account
5. ✅ Submit for TestFlight beta

---

**Note**: Xcode project files (.pbxproj) are complex and fragile. Always use Xcode's GUI to add files rather than editing the project file manually.
