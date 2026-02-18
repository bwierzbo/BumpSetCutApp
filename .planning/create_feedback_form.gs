function createBetaFeedbackForm() {
  var form = FormApp.create('BumpSetCut Beta Feedback');
  form.setDescription(
    'Thanks for testing BumpSetCut! Submit one response per issue you find.\n' +
    'Quick reports are totally fine — don\'t overthink it.\n\n' +
    'For screenshots: hold Power + Volume Up to capture your screen.'
  );
  form.setCollectEmail(true);
  form.setAllowResponseEdits(true);
  form.setConfirmationMessage('Thanks! Your feedback helps make BumpSetCut better. Submit another response if you find more issues.');

  // Q1 - What were you trying to do?
  form.addTextItem()
    .setTitle('What were you trying to do?')
    .setHelpText('e.g. "Upload a video", "Watch rallies", "Export a clip"')
    .setRequired(true);

  // Q2 - What happened?
  form.addParagraphTextItem()
    .setTitle('What happened?')
    .setHelpText('Describe what you saw — error messages, freezes, weird behavior')
    .setRequired(true);

  // Q3 - What did you expect?
  form.addParagraphTextItem()
    .setTitle('What did you expect to happen?')
    .setHelpText('What should have happened instead?')
    .setRequired(true);

  // Q4 - Severity
  form.addMultipleChoiceItem()
    .setTitle('How bad is it?')
    .setChoiceValues([
      'Blocker — I can\'t use the app',
      'Annoying — It works but something\'s wrong',
      'Minor — Small visual or wording issue',
      'Suggestion — Not a bug, just an idea'
    ])
    .setRequired(true);

  // Q5 - Area
  form.addListItem()
    .setTitle('Which area of the app?')
    .setChoiceValues([
      'Onboarding / First launch',
      'Uploading a video',
      'Library / Folders / Search',
      'Processing a video',
      'Watching rallies',
      'Exporting',
      'Settings / Account',
      'Other'
    ])
    .setRequired(true);

  // Q6 - Screenshot
  form.addFileUploadItem()
    .setTitle('Screenshot or screen recording')
    .setHelpText('Optional but super helpful')
    .setRequired(false);

  // Q7 - Device
  form.addTextItem()
    .setTitle('Your device')
    .setHelpText('e.g. "iPhone 15 Pro, iOS 18.3"')
    .setRequired(true);

  // Q8 - Anything else
  form.addParagraphTextItem()
    .setTitle('Anything else?')
    .setHelpText('General impressions, ideas, frustrations — all welcome')
    .setRequired(false);

  // Page break + general feedback section
  form.addPageBreakItem()
    .setTitle('Overall Impressions (Optional)');

  form.addScaleItem()
    .setTitle('Overall, how would you rate the app so far?')
    .setBounds(1, 5)
    .setLabels('Rough', 'Solid')
    .setRequired(false);

  form.addParagraphTextItem()
    .setTitle('What\'s the best thing about the app?')
    .setRequired(false);

  form.addParagraphTextItem()
    .setTitle('What\'s the most frustrating thing?')
    .setRequired(false);

  Logger.log('Form created: ' + form.getEditUrl());
  Logger.log('Share this link with testers: ' + form.getPublishedUrl());
}
