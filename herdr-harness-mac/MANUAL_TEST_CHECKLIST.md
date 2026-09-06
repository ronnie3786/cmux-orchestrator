# Herdr Mac manual test checklist

Use `/Applications/Herdr.app` on the Work Mac. Check off each item after trying it.

- [ ] **Session bubbles:** Start a Pi chat and send a clear request. Its bubble should gain a short topic title and emoji, with status below. The private AI model chooses the label from your prompts. While waiting, or if AI is unavailable, Herdr keeps the original title and a chat emoji.

- [ ] **HUD attachments:** Drop an image and a small text file from Finder into the open HUD. Check the attachment chips, remove one, and send the other. Repeat with a file and no message. Sent files appear in chat; Herdr keeps a copy so attachments survive moving the original and restarting.

- [ ] **Favorite models and short names:** In a model picker, choose **Favorite [current model]** or **Manage Favorites**. Favorites should appear first in HUD and chat-pane pickers, using consistent short names. Unfavorite one and restart to check persistence. Matching names from different providers remain distinguishable.

- [ ] **Code-block paste:** Copy code and click **Paste Code Block** in each composer. The draft should contain opening triple backticks, your text on the next lines, and closing triple backticks. It waits for you to send. Existing backticks get a longer outer fence so the pasted block stays intact.

- [ ] **No false overflow notification:** With four or more Pi sessions and all alerts read, collapse the HUD. **+1** or **+N** should count extra sessions without creating a red notification border or badge. Actual unread results still trigger attention.

- [ ] **Session links and files:** Have two agents produce different links or result files. Each should attach to its own session bubble and appear inside that chat. Read one session: only its unread indicators should clear. Its result cards should remain in chat history.

- [ ] **Prompt history:** Submit several prompts, then click **Prompt history** in the pane header. Search, expand, copy, and **Reuse** an older prompt. Reuse replaces the draft without sending. Switch panes and restart: history should stay separate and persist. This saves new submissions and imports available earlier prompts; it cannot recover already-lost history.

- [ ] **Compact notes:** Hover over several notes. They should stay as compact title strips until clicked. Close an opened note to return to the compact stack; scroll to reach older notes.

- [ ] **Smaller hover area:** Move the pointer near, then onto, the HUD and notes. Nearby empty space should trigger fewer accidental hover effects; visible controls should remain easy to use.

- [ ] **Recording permissions:** In **Settings > Screen & System Audio Recording**, use **Identify this copy of Herdr** and **Test Access**. If access fails, quit Herdr, remove the stale macOS permission entry, add `/Applications/Herdr.app`, enable it, and reopen. The test lists displays, without recording. This adds diagnosis and recovery; macOS still needs your grant, and replacing this build can change its signing identity. [Recovery instructions](RECORDING_PERMISSIONS.md).

## iPhone notification checks require follow-up setup

The backend waits until an agent has been **finished or needs attention for 60 seconds unread**, then sends an iPhone notification. Reading, closing, or resuming the session cancels pending delivery. Failed deliveries retry without repeating successful ones.

**Not ready to test:** Apple push credentials are missing on the Work Mac, so background pushes cannot work yet. This deployment also does not install the changed iOS app. A new iOS build is needed to verify its one-minute local fallback and notification cleanup when read state syncs. The older iOS app may still notify sooner.

Once Apple push is configured and the updated iOS app is installed with notifications enabled:

- [ ] Let an agent finish while the iPhone app is in the background. Leave the session unread for more than a minute. Expect one notification; tap it and confirm it opens the correct machine and chat.
- [ ] Repeat, but read the session within the first minute. Expect no delayed push for that result.
- [ ] With the iOS app connected, verify its local fallback also waits a minute and that reading the session clears matching notifications when read state syncs.
