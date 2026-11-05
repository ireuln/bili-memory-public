# B-Impression (English)

<p><a href="README.md">中文</a> · English (this page)</p>

A local-first archive for your Bilibili watch history and favorites, with one
feature the official product does not have: **invalid tracking**. Favorites die.
In a real archive of about 14,000 favorites, roughly 15% were already gone. Every
scan re-checks each favorite, so "what disappeared, when, and what it used to be"
becomes a list you can search instead of a memory you lose.

The full Chinese documentation is in [README.md](README.md). This page is the
short English guide.

## Get started in three steps

1. Download the latest release from [Releases](https://github.com/ireuln/bili-memory-public/releases) and unzip it (Windows 10/11, nothing to install).
2. Run `B印象.exe`, pick a data folder (the disk with the most free space is the default).
3. Right-click the tray icon → **Sign in with QR code**, then scan it with the Bilibili app on your phone.

After that, click **Collect watch history now** in the tray and you have a first archive in minutes.

## What you need

- Windows 10 1809+ or Windows 11
- Windows PowerShell 5.1 (built into Windows; nothing to install)
- Edge or Chrome (only used to render share cards and screenshots)

## What you get

| Output | Example |
|---|---|
| `收藏总表.jsonl` (favorites master) | ~14k rows with `invalid` / `invalid_since` |
| Invalid list | ~2,000 dead favorites with time, uploader, folder, cover |
| `*.md` per folder | readable tables grouped by favorite folder |
| Cover snapshots | ~12k 320px covers, so a dead video is still recognizable |
| Watch history `YYYY-MM.jsonl` | last ~1200 items, incremental daily |
| Reports `report-*.md` | watch time, categories, uploader ranking, completion |
| Encrypted backup `.7z` | AES-256, two targets, keeps the latest 5 |

## Quick start

1. **Sign in once** from the tray menu. The session file under the login-state
   folder is equivalent to your account: do not copy it, do not upload it.
2. **First run**: tray → *Collect watch history now*. A full favorites scan takes
   about 20 minutes; the daily increment takes seconds.
3. **Read the settings page**: tray → *Features & settings*. Change a switch and
   it saves immediately; scheduled-task changes apply only after *Apply scheduled
   tasks*.
4. **Set the schedule** under *Schedule & automation*.
5. **Back up** under *Share & backup*: fill the targets and build one archive
   manually before relying on the schedule.

## English UI

Set `"UiLanguage": "en-US"` in `config.json` (or pick it in the setup window).

- Tray menu, notices, share cards, and the paste-ready post text switch to English.
- Data paths, folder names, video titles, and uploader names stay as-is — they
  are your data, not interface copy.
- Strings live in `lang/en-US.json`; a missing key falls back to Chinese, so the
  tool never shows a blank or throws. The native setup/settings window is
  Chinese-only for now.

## Risks and boundaries (read this once)

- **Platform terms**: the Bilibili user agreement (4.2.11) forbids obtaining platform data with scripts or automated programs; it has no "my own data" exception. This project claims no written permission and provides no way to bypass platform rules — whether to use it is your call.
- **Account**: it uses the web client endpoints, not an open API. Higher frequency means rate limits, temporary blocks, or a lost session; endpoints can change at any time.
- **Privacy**: a watch history can reveal political leanings, emotions, and health. Data is written locally and never uploaded. The login-state folder is equivalent to your account — never copy, upload, or share it.
- **Antivirus false positives**: unsigned executables may be blocked by Huorong/Defender (especially `start.cmd` and hidden PowerShell). Restore from quarantine and trust the tool folder; never disable global protection.
- **Credentials**: do not paste cookies, SESSDATA, or the login-state folder into issues, chats, or someone else's AI. Public = leaked; rotate immediately.
- **Official releases only**: download from this repository's Releases page. Re-packaged forks cannot be verified.

## Feedback

Testing, feature requests, bug reports, and usage questions are welcome — this is an early tool and real accounts hit edge cases the author cannot predict.

- **Bugs / requests**: open an [issue](https://github.com/ireuln/bili-memory-public/issues). Include the version, Windows build, and steps. Never paste cookies / SESSDATA / the login-state folder / logs with real titles or uids (see [SECURITY.md](SECURITY.md)).
- **Out of scope (will not be implemented)**: downloading videos, bypassing rate limits / membership / paywalls, scraping other people's data, account trading, automation abuse, or anything that fights the platform.
- **PRs**: welcome; open an issue first so we can agree on the scope.

## Limits

- Invalid tracking covers **favorited videos only**. Feed posts and articles have
  no reliable invalid signal, so they are not tracked.
- Anonymous (not signed in) access can read public video metadata, but watch
  history, favorites, and follows require a signed-in session.
- Windows-only by design. No cloud, no account system of its own, no telemetry.

## Files

```
config.json            settings (UiLanguage lives here)
tray.ps1               tray icon, menus, floating card, notifications
collect.ps1            history / favorites / feed collector
query.ps1 report.ps1   read-only query and report
share.ps1              share card + paste-ready post text
backup-package.ps1     archive (ZIP by default, 7z with -Encrypt)
selftest.ps1           read-only install check
tools/regress.ps1      encoding + static analysis + self test
```
