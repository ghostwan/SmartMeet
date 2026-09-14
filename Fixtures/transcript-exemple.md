# Transcript — Home + Security weekly meeting
Date: 09/11/2026 — Duration: 32 min

**[00:00] Moi:** Hi everyone. We have three topics today: the Crowdin migration, the delay on the indoor camera API, and the iOS beta preparation.

**[00:18] Participants:** Hey Alex. On Crowdin, I've finished the API integration on the build side. What's left is validating the German and Italian translations, Sandra needs to pick that up.

**[00:41] Moi:** Sandra, do you think you can wrap that up by Friday?

**[00:47] Participants:** Friday's too tight, I have a client spec review in parallel. I can commit to next Tuesday if nobody adds new keys before then.

**[01:05] Moi:** OK, we freeze new Crowdin keys until Tuesday then. I'll tell the product team.

**[01:20] Participants:** On the camera API, we're two weeks behind. The firmware isn't returning motion detection events in the right format, the embedded team says it's a protobuf serialization issue.

**[01:48] Moi:** Two weeks, does that impact the beta?

**[01:52] Participants:** Yes. If we don't unblock it before the 25th, the iOS beta slips by a sprint. Martin is proposing a cloud-side workaround: we normalize the payload in the gateway instead of waiting for the firmware fix.

**[02:20] Moi:** The workaround, how many days is that?

**[02:24] Participants:** Three days of dev, plus a day of testing. But it creates debt: we'll need to remove it once the firmware is fixed.

**[02:40] Moi:** Let's go with it. It's better than a sprint of delay. Martin, open a ticket for the workaround and another one for removing the debt, so we don't forget it.

**[02:58] Participants:** Noted. I'll create them today.

**[03:05] Moi:** Last point, the iOS beta. Where are we on tester recruitment?

**[03:14] Participants:** 340 signed up out of the 500 we're targeting. Recruitment through the newsletter worked better than expected. We can open it up to other countries if needed.

**[03:32] Moi:** Open it up to Germany and Spain. We'll decide on the beta go/no-go at the committee on the 18th.

**[03:45] Participants:** One question: do we communicate the camera delay to testers?

**[03:52] Moi:** No, not until the workaround is validated in testing. We'll re-assess on the 18th.
</content>
