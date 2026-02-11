# Legal Documents Deployment Instructions

This guide explains how to deploy the Privacy Policy and Terms of Service for BumpSetCut.

## Files Created

- `legal/PRIVACY_POLICY.md` - Comprehensive privacy policy
- `legal/TERMS_OF_SERVICE.md` - Complete terms of service
- `legal/DEPLOYMENT_INSTRUCTIONS.md` - This file

## Required URLs

The app expects these documents to be hosted at:

1. **Privacy Policy**: https://bumpsetcut.com/privacy
2. **Terms of Service**: https://bumpsetcut.com/terms
3. **Community Guidelines**: https://bumpsetcut.com/community-guidelines (TODO)

## Deployment Options

### Option 1: Static Website (Recommended)

Host the documents on a simple static website:

#### Using GitHub Pages (Free)

1. Create a GitHub repository: `bumpsetcut-website`
2. Convert markdown to HTML:
   ```bash
   # Install markdown converter
   npm install -g markdown-pdf marked

   # Or use an online converter like:
   # https://markdowntohtml.com/
   # https://dillinger.io/
   ```

3. Create HTML files:
   - `privacy.html` → Host at `/privacy`
   - `terms.html` → Host at `/terms`
   - `community-guidelines.html` → Host at `/community-guidelines`

4. Add basic styling (optional but recommended):
   ```html
   <!DOCTYPE html>
   <html>
   <head>
       <title>BumpSetCut Privacy Policy</title>
       <meta name="viewport" content="width=device-width, initial-scale=1.0">
       <style>
           body {
               font-family: -apple-system, BlinkMacSystemFont, sans-serif;
               max-width: 800px;
               margin: 0 auto;
               padding: 20px;
               line-height: 1.6;
           }
           h1 { color: #FF6B35; }
           h2 { color: #333; margin-top: 30px; }
           a { color: #007AFF; }
       </style>
   </head>
   <body>
       <!-- Paste converted HTML here -->
   </body>
   </html>
   ```

5. Configure custom domain (bumpsetcut.com) in GitHub Pages settings

#### Using Netlify/Vercel (Free)

1. Create a simple Next.js or static site
2. Add markdown files to `/public` or create pages
3. Deploy to Netlify/Vercel
4. Connect custom domain

### Option 2: Simple Web Server

If you have a server:

```bash
# Create web directory
mkdir -p /var/www/bumpsetcut.com/legal

# Convert and upload HTML files
scp privacy.html user@server:/var/www/bumpsetcut.com/privacy/index.html
scp terms.html user@server:/var/www/bumpsetcut.com/terms/index.html

# Configure nginx
server {
    server_name bumpsetcut.com;
    root /var/www/bumpsetcut.com;

    location /privacy {
        try_files $uri $uri/ /privacy/index.html;
    }

    location /terms {
        try_files $uri $uri/ /terms/index.html;
    }
}
```

### Option 3: Notion/Google Docs (Quick Start)

For immediate deployment while setting up a proper website:

1. **Notion** (Free):
   - Create a Notion page for each document
   - Enable "Share to web"
   - Get public URL
   - Use a URL shortener to map to clean URLs

2. **Google Docs**:
   - Upload markdown files
   - Publish to web
   - Get shareable links

**Note**: Update URLs in PaywallView.swift and SettingsView.swift if using temporary URLs.

## Required Updates

### 1. Email Addresses

Update placeholder email addresses in the documents:

- `privacy@bumpsetcut.com` → Your actual privacy email
- `support@bumpsetcut.com` → Your actual support email
- `legal@bumpsetcut.com` → Your actual legal email
- `dmca@bumpsetcut.com` → Your actual DMCA contact

### 2. Governing Law

In Terms of Service, update Section 14.1:

```markdown
These Terms are governed by the laws of [Your State/Country]
```

Replace `[Your State/Country]` with your actual jurisdiction (e.g., "California, United States").

### 3. Company Information

If you have a registered company, add:
- Company legal name
- Registration number
- Registered address
- Contact information

### 4. Community Guidelines

Create a separate Community Guidelines document covering:
- Acceptable content types
- Prohibited behaviors
- Reporting process
- Examples of violations
- Enforcement actions

## App Store Connect Configuration

1. Log in to App Store Connect
2. Navigate to your app → App Information
3. Under "General Information":
   - Privacy Policy URL: `https://bumpsetcut.com/privacy`
   - (Optional) Support URL: `https://bumpsetcut.com/support`

## Testing

Before submitting to App Store:

1. **Test all links**:
   - Open PaywallView in app
   - Tap "Privacy Policy" → Should open in Safari
   - Tap "Terms of Service" → Should open in Safari
   - Open SettingsView → Legal section
   - Test all three links

2. **Verify mobile rendering**:
   - Open URLs on iPhone/iPad
   - Check text is readable
   - Ensure proper responsive design
   - Test light/dark mode if applicable

3. **Check accessibility**:
   - Proper heading structure (H1, H2, H3)
   - Readable font sizes
   - Sufficient color contrast

## Maintenance

### When to Update

Update documents when you:
- Add new features that collect data
- Change subscription pricing
- Modify data retention policies
- Update third-party services (e.g., switch from Supabase)
- Add new social features
- Change moderation policies

### Version Control

- Keep markdown files in git repository
- Update "Last Updated" date at top of each document
- Consider adding version history section
- Notify users of material changes (in-app notification)

## Compliance Checklist

Before App Store submission:

- [ ] Privacy Policy hosted at correct URL
- [ ] Terms of Service hosted at correct URL
- [ ] Community Guidelines created and hosted
- [ ] All links tested and working
- [ ] Email addresses updated
- [ ] Governing law specified
- [ ] URLs added to App Store Connect
- [ ] Documents reviewed by legal counsel (recommended)
- [ ] Mobile-friendly rendering verified
- [ ] GDPR compliance verified (if targeting EU)
- [ ] CCPA compliance verified (if targeting California)

## Legal Disclaimer

**IMPORTANT**: These documents were created as templates and may not cover all legal requirements for your specific situation. We strongly recommend:

1. Have a lawyer review these documents
2. Customize for your specific business structure
3. Ensure compliance with local laws and regulations
4. Update regularly as your app evolves

The templates cover general requirements but may need adjustments based on:
- Your location and target markets
- Specific features you implement
- Data processing practices
- Third-party integrations
- Business model changes

## Resources

- [App Store Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)
- [Apple Privacy Requirements](https://developer.apple.com/app-store/user-privacy-and-data-use/)
- [GDPR Compliance](https://gdpr.eu/)
- [CCPA Compliance](https://oag.ca.gov/privacy/ccpa)
- [Privacy Policy Generators](https://www.privacypolicies.com/)

## Support

If you need help deploying these documents:

1. Check GitHub issues for common problems
2. Consult web hosting documentation
3. Consider hiring a web developer for professional setup
4. Consult legal counsel for compliance questions

---

**Quick Start Summary**:

1. Convert markdown to HTML
2. Host at bumpsetcut.com/privacy and bumpsetcut.com/terms
3. Update placeholder emails and jurisdiction
4. Add URLs to App Store Connect
5. Test all links from the app
6. Have lawyer review (recommended)
7. Submit to App Store

Good luck with your App Store submission! 🚀
