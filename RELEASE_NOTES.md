# Copy 4 AI 3.2.0

Copy 4 AI turns Word, PDF and PowerPoint files into clean text that you can
paste into ChatGPT, Claude or another AI chat. Everything happens on your Mac:
nothing is uploaded, and no account is needed.

## Please read this first: opening the app

Copy 4 AI is made by an individual, not a large company. The app is signed
locally (called **ad-hoc signed**) but has not been checked and approved by
Apple (called **notarized**). macOS will therefore probably warn you the first
time you open it. The warning is expected. You only need to get past it once.

1. Download `Copy4AI-3.2.0-arm64.dmg` from this release page.
2. Double-click the DMG, drag **Copy 4 AI** into **Applications**, then eject
   the DMG. Do not open the app from inside the DMG.
3. Open **Applications** and double-click **Copy 4 AI**.
4. macOS will say it cannot verify the app. Click **Done** (or **OK**). Do
   **not** click **Move to Trash**.
5. Open **System Settings** (Apple menu > System Settings).
6. Click **Privacy & Security** in the sidebar.
7. Scroll down to the **Security** section. Next to the message about
   Copy 4 AI, click **Open Anyway**.
8. Enter your Mac password or use Touch ID.
9. If macOS asks again, click **Open** (or **Open Anyway**).
10. Copy 4 AI opens and shows a short welcome message. Click **OK**.

If you do not see **Open Anyway**, double-click the app again and return to
Privacy & Security. The button appears only after macOS has blocked the app.

If macOS says the app is damaged, delete that copy, download the DMG again, and
repeat the steps. A fresh download usually fixes it.

On macOS 15 and later, the old trick of right-clicking the app and choosing
**Open** does not bypass this warning. Use the steps above.

After the first time, you can open the app normally.

## Using it

1. Select one or more Word, PDF or PowerPoint files in Finder.
2. Right-click and choose **Services**.
3. Choose **Copy 4 AI** to read text from pictures and scans too, or
   **Copy 4 AI (no OCR)** for a faster run that only reads text already in the
   file.
4. When the progress panel finishes, paste into your AI chat.

## What's new in 3.2.0

- Faster when converting several files at once.
- Better at finding text inside images in PDFs, including images on hidden
  layers and images that overlap other images.
- More reliable page and image placement in PDF output.

## Good to know

- Requires an Apple Silicon Mac and macOS 15 or later.
- The security warning is normal for apps distributed outside the App Store.
  Do not turn off macOS security settings.
- Only download Copy 4 AI from this release page.
- If you used 3.1.0, replace the old app in Applications with this one.
- More details, including uninstall instructions, are in the README.

Copy 4 AI is released under the MIT License.
