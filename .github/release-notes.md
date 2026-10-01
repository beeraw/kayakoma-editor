## Requirements

macOS 14 or later.

## Install

1. Download `{{ASSET}}` below and unzip it.
2. Move **Kayakoma Editor** to your Applications folder.

## First open

The app is not signed with an Apple Developer ID and is not notarized by Apple, so macOS blocks it the first time you open it. To allow it once:

- Open **System Settings › Privacy & Security**, scroll down and click **Open Anyway** next to the message about Kayakoma Editor, then confirm; or
- right-click the app in the Finder, choose **Open**, then confirm.

Alternatively, remove the quarantine flag in Terminal:

```bash
xattr -dr com.apple.quarantine "/Applications/Kayakoma Editor.app"
```

## Checksum

SHA-256 of `{{ASSET}}`:

```
{{SHA256}}
```
