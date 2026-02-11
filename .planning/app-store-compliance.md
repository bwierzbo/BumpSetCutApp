# App Store Compliance Checklist

## ✅ Completed

### StoreKit 2 Integration
- [x] Created StoreManager with StoreKit 2
- [x] Implemented subscription purchase flow
- [x] Transaction verification and entitlement checking
- [x] Restore purchases functionality
- [x] Created Configuration.storekit for testing
- [x] Product ID: `com.bumpsetcut.pro.monthly` ($7.99/month)

### UI Components
- [x] PaywallView with feature list and pricing
- [x] Subscription section in Settings
- [x] "Manage Subscription" deep link (for Pro users)
- [x] Free tier limits display

### Code Safety
- [x] Wrapped testing helpers in `#if DEBUG`
- [x] Removed UserDefaults-based Pro status from production
- [x] SubscriptionService now uses StoreManager exclusively

### Privacy Compliance
- [x] NSPhotoLibraryUsageDescription
- [x] NSPhotoLibraryAddUsageDescription
- [x] NSCameraUsageDescription

### Content Moderation (App Store Guideline 1.2)
- [x] Database schema for reports and blocks (002_content_moderation.sql)
- [x] Content reporting system (ReportContentSheet)
- [x] User blocking feature (BlockUserAlert, ModerationService)
- [x] Report highlights integration (HighlightCardView menu)
- [x] Report comments integration (CommentsSheet context menu)
- [x] 8 report types with clear descriptions
- [x] Client-side filtering of blocked users

---

## 🚧 Remaining Tasks

### App Store Connect Setup
- [ ] Create app in App Store Connect
- [ ] Configure subscription in App Store Connect:
  - Product ID: `com.bumpsetcut.pro.monthly`
  - Price: $7.99/month
  - Display name: "BumpSetCut Pro"
  - Description: "Unlimited video processing, no watermarks, and process on cellular data"
- [ ] Set up subscription group
- [ ] Configure App Store metadata (screenshots, description, keywords)

### Legal & Policy Requirements
- [ ] Create Privacy Policy (required for App Store)
  - Host at: https://yourwebsite.com/privacy
  - Cover: data collection, Supabase backend, user-generated content
- [ ] Create Terms of Service
  - Host at: https://yourwebsite.com/terms
  - Cover: subscription terms, auto-renewal, cancellation policy
- [ ] Update PaywallView with policy links (lines 167-177)
- [ ] Add privacy policy URL to App Store Connect

### Content Moderation (Social Features)
- [x] Implement content reporting system ✅
- [x] Add "Report" button to highlights and comments ✅
- [x] Store reports in Supabase (schema created) ✅
- [x] Implement user blocking feature ✅
- [ ] Create moderation dashboard/process (backend admin tool)
- [ ] Add community guidelines document
- [ ] Run Supabase migration: 002_content_moderation.sql
- [ ] Add age rating compliance (set to 12+ in App Store Connect)

### Backend Security
- [ ] Review Supabase Row Level Security policies
- [ ] Implement rate limiting for API calls
- [ ] Add profanity filter for comments/usernames
- [ ] Set up backend monitoring/alerts

### Testing
- [ ] Test StoreKit in sandbox environment
- [ ] Test subscription purchase flow end-to-end
- [ ] Test restore purchases on new device
- [ ] Test subscription expiration handling
- [ ] Test grace period and billing retry states
- [ ] Verify watermark appears for free users
- [ ] Verify watermark removed for Pro users

### Xcode Project Configuration
- [ ] Add StoreManager.swift to Xcode project
- [ ] Add PaywallView.swift to Xcode project
- [ ] Add Configuration.storekit to Xcode project
- [ ] Configure StoreKit testing in Xcode scheme
- [ ] Update app version and build number
- [ ] Configure code signing for distribution

### Optional but Recommended
- [ ] Add subscription intro offer (e.g., 7-day free trial)
- [ ] Add promotional offers for lapsed subscribers
- [ ] Implement subscription analytics tracking
- [ ] Add "Share with friend" referral system
- [ ] Create App Store promotional assets

---

## 📋 Pre-Submission Checklist

### Required for Submission
1. [ ] Privacy Policy URL configured in App Store Connect
2. [ ] Terms of Service URL configured in PaywallView
3. [ ] Subscription product created and approved in App Store Connect
4. [ ] All privacy usage descriptions present in Info.plist
5. [ ] Content reporting mechanism implemented
6. [ ] Age rating appropriate for social features
7. [ ] App screenshots and metadata complete
8. [ ] Test builds submitted to TestFlight

### Testing Sign-Off
1. [ ] Subscription purchase works in sandbox
2. [ ] Restore purchases works correctly
3. [ ] Free tier limits enforced (3 videos/week, 500MB, WiFi-only)
4. [ ] Pro tier unlocks all features
5. [ ] Watermark added for free users
6. [ ] Watermark removed for Pro users
7. [ ] Network restrictions work (WiFi vs cellular)
8. [ ] Social features tested (auth, comments, follows, likes)

### Code Quality
1. [ ] No debug code in production builds
2. [ ] All TODO comments addressed
3. [ ] No test credentials in code
4. [ ] Secrets.swift is gitignored
5. [ ] Build succeeds with zero warnings

---

## 🔗 Important Links

- **StoreKit 2 Documentation**: https://developer.apple.com/documentation/storekit
- **App Store Review Guidelines**: https://developer.apple.com/app-store/review/guidelines/
- **Subscription Best Practices**: https://developer.apple.com/app-store/subscriptions/
- **Privacy Policy Generator**: https://www.privacypolicies.com/

---

## 💰 Revenue Model

### Pricing Strategy
- **Free Tier**: 3 videos/week, 500MB max, WiFi-only, watermarked
- **Pro Tier**: $7.99/month
  - Unlimited processing
  - Unlimited file size
  - Cellular processing
  - No watermarks
  - Priority support (future)
  - Advanced settings (future)

### Target Metrics
- Conversion rate: 5-10% free → paid
- Monthly churn: <5%
- LTV target: $100+ (13+ months retention)

---

## Notes

- StoreKit Configuration file is for local testing only
- Real subscription products must be created in App Store Connect
- Subscription group allows future tiers (e.g., annual plan, team plans)
- All StoreKit 2 features are iOS 15+ compatible
- Transaction verification happens automatically via VerificationResult
- Debug testing helpers only work in DEBUG builds (stripped in Release)
