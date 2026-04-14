# Reposter

Minimal Flutter app for importing a public TikTok or Instagram post URL, caching the video inside the app, and handing it off to Instagram or TikTok for the final publish step.

## What it does

- Paste an Instagram or TikTok post URL.
- Detects which platform it came from.
- Scrapes the page for the video, author, and description.
- Stores the video inside the app by default.
- Optionally saves a copy into the device Downloads folder.
- Opens Instagram or TikTok with the video attached on Android.
- Copies the caption so you can paste it into the target app.

## Limits

- This is a UI-first, no-API approach.
- It works best for public posts where the page exposes a direct video URL in its HTML.
- Instagram and TikTok still control the final composer, so caption prefilling is best-effort and the app also copies the caption to the clipboard.
- iOS falls back to the system share sheet instead of opening a specific target app directly.
