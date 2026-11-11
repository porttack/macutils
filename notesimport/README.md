# Scans to Notes

A small Mac toolkit for turning scanned PDFs into Apple Notes entries. Each scan gets its own note with a title, scan and import dates, an on-device AI summary, a link back to the original file, and the scan itself attached. Image-only scans are also made searchable by adding an invisible OCR text layer to the PDF.

Everything runs on the Mac. OCR uses Apple's Vision framework and summaries use Apple Intelligence's on-device model, so document contents never leave the machine.

**Contents:** [Components](#components) · [Requirements](#requirements) · [Installation](#installation) · [Using it](#using-it) · [How Import Scans to Notes works](#how-import-scans-to-notes-works) · [How summarize-pdf works](#how-summarize-pdf-works) · [Maintaining and updating](#maintaining-and-updating) · [Troubleshooting](#troubleshooting) · [Files](#files)

## Components

| Piece | What it is | Where it lives |
|---|---|---|
| **Import Scans to Notes** | An AppleScript inside an Automator Quick Action. You run it from Finder on one or more PDFs. | Source: `importscan.applescript`. Installed as `~/Library/Services/<name>.workflow` |
| **summarize-pdf** | A Swift command-line tool. It downloads iCloud-only files, OCRs image-only scans, adds a searchable text layer, and prints a summary. | Source: `summarize-pdf.swift`. Installed as `/usr/local/bin/summarize-pdf` |
| **Open Scan** | A Shortcuts shortcut. It's run by the "Find Scan" link in each note and finds a scan by filename, even after it has been moved. | The Shortcuts app (the script is in [Installation, step 3](#3-create-the-open-scan-shortcut)) |

The AppleScript calls `summarize-pdf` for the summary and builds the "Find Scan" link that runs `Open Scan`. Each piece also works on its own: `summarize-pdf` is a useful command in Terminal, and the Quick Action still creates notes (without summaries) if the tool is missing.

## Requirements

- An Apple silicon Mac running macOS 26 (Tahoe) or later, with Apple Intelligence turned on
- Xcode or the Command Line Tools (`xcode-select --install`) with the macOS 26 SDK, to build the Swift tool
- A folder named **Scans** in Apple Notes (or change `notesFolderName` in the script)
- Scans saved as PDFs, ideally named `YYYY-MM-DD Description.pdf` (for example `2026-03-14 Water bill.pdf`)

## Installation

### Change these for your setup

The defaults were written for one person's Mac. Before you install, decide what to change:

| What | Where | Default | Change it to |
|---|---|---|---|
| `scannedBy` | Top of `importscan.applescript` | The author's name | Your name. It appears in each note's "Scanned by" line. |
| `notesFolderName` | Top of `importscan.applescript` | `"Scans"` | The Notes folder to use. Create it in Notes first. |
| `roots` | The Open Scan shortcut's script ([step 3](#3-create-the-open-scan-shortcut)) | A Readdle Scanner Pro iCloud folder and `~/Documents/Other Scans` | The folders where your scans are saved |

### 1. Build and install summarize-pdf

From this folder:

```
sudo mkdir -p /usr/local/bin
make install
```

`make` builds `summarize-pdf` here (it's gitignored) and `make install` copies it to `/usr/local/bin` with `sudo`. The `mkdir` is needed on Macs where `/usr/local/bin` doesn't exist yet. It's already on the default PATH once it exists, and Homebrew on Apple silicon uses `/opt/homebrew`, so nothing else will overwrite the tool there. Set `PREFIX` to install elsewhere (`make install PREFIX=~/.local`, though the AppleScript expects `/usr/local/bin`). The build takes a few seconds.

Check that it works:

```
summarize-pdf --dry-run ~/path/to/some-scan.pdf
```

You should see a few `DEBUG:` lines followed by a one-paragraph summary. Rebuild after major macOS or Xcode updates.

### 2. Create the Quick Action

1. Open **Automator** and choose **New Document → Quick Action**.
2. At the top, set **Workflow receives current** to **PDF files** in **Finder**.
3. Drag in a **Run AppleScript** action.
4. Replace its contents with the full text of `importscan.applescript`. In Terminal, `pbcopy < importscan.applescript` copies the whole file to the clipboard.
5. Click the hammer icon to compile, then save the workflow as **Import Scans to Notes**.

Automator saves it in `~/Library/Services`. To edit it later, open the `.workflow` file there.

### 3. Create the Open Scan shortcut

In the Shortcuts app, create a shortcut named exactly **Open Scan** with these actions:

1. **Receive** Text input. (The easiest way to get this block is to add the next action, then right-click its input and choose **Shortcut Input**.)
2. **Get text from** Shortcut Input.
3. **Run Shell Script**, with Shell set to **zsh**, Input set to the text from step 2, and Pass Input set to **as arguments**:

   ```zsh
   roots=(
     "$HOME/Library/Mobile Documents/iCloud~com~readdle~Scanner~PDF/Documents"
     "$HOME/Documents/Other Scans"
   )

   # 1. Exact-name search in the scan folders (includes all subfolders)
   f=$(find "${roots[@]}" -type f -name "$1" -print -quit 2>/dev/null)

   # 2. Fall back to Spotlight anywhere in the home folder
   if [[ -z "$f" ]]; then
     for g in "${(@f)$(mdfind -onlyin "$HOME" -name "$1")}"; do
       [[ "${g:t}" == "$1" ]] && { f="$g"; break; }
     done
   fi

   if [[ -n "$f" ]]; then open "$f"; else echo "Not found: $1"; fi
   ```

4. **If** Shell Script Result **has any value**: **Show Notification** with Shell Script Result.
5. **Otherwise**: **Hide App** → Shortcuts.
6. **End If**.

Edit the `roots` list to match wherever your scans are saved. The search includes every subfolder, so year folders and later reorganizing are handled automatically.

### 4. Grant permissions

macOS asks for some of these the first time each piece runs. Approve them as they come up.

- **Automation:** allow the Quick Action to control Notes.
- **Shortcuts → Settings → Advanced → Allow Running Scripts:** required for the Run Shell Script action in Open Scan.
- **Full Disk Access** (only if Open Scan reports it can't read a folder): add Shortcuts under System Settings → Privacy & Security.

## Using it

In Finder, select one or more PDFs, right-click, and choose **Quick Actions → Import Scans to Notes**. With a single file, Notes opens to the new note when it's done. If anything was skipped or failed, a notification says so.

**Try it on a copy of one scan first.** Besides creating the note, the tool rewrites image-only PDFs in place (it adds the text layer and stores the summary in the Subject field), and the file gets tagged. To see what the tool would do without changing anything, run `summarize-pdf --dry-run file.pdf` in Terminal. To never modify PDFs, set `addTextLayer` to `false` in the Swift source and rebuild.

Each note looks like this:

> **2026-03-14 Water bill**
>
> Scanned by … on 2026-03-14 at 09:12:44, imported on 2026-11-04 at 20:15:02
>
> **Summary:** A two-to-three sentence summary of the document.
>
> Original file: 2026-03-14 Water bill.pdf (Find Scan)
>
> [the attached PDF]

Afterward, the PDF gets a green Finder tag so you can see which scans have been imported.

## How Import Scans to Notes works

For each selected file, the script does the following:

1. **Builds the title and dates.** If the filename starts with a `YYYY-MM-DD` date, that date and the rest of the name become the note title. Otherwise the whole filename is used. The scan date comes from the filename. The file's creation time is used only when it falls on the same day, because a copied or synced file gets a new creation time. If the filename has no date, the creation time is used as the scan date.
2. **Gets a summary** by running `/usr/local/bin/summarize-pdf` on the file (see below). Progress output from the tool is discarded. If the tool fails for any reason, the note is created without a summary.
3. **Builds two links back to the file.** **Original file** is a file ID link (`file:///.file/id=…`), which follows the file if it's moved or renamed on this Mac. **Find Scan** is a `shortcuts://` link that runs Open Scan with the filename, so it survives moves anywhere in the searched folders but not renames. The file ID link is built after `summarize-pdf` runs, because that tool may have replaced the file with a searchable copy.
4. **Creates the note** in the Scans folder and attaches the PDF.
5. **Tags the file Green**, but only after the note was created successfully.

Text from filenames and summaries is HTML-escaped, so names containing `&` or `<` display correctly.

### Settings

These are `property` lines at the top of the script.

| Setting | Default | Purpose |
|---|---|---|
| `notesFolderName` | `"Scans"` | Notes folder that receives new notes |
| `doneTag` | `"Green"` | Finder tag added after a successful import |
| `skipAlreadyTagged` | `false` | `true` skips files that already have the tag. `false` always imports, so importing the same file twice makes two notes, and the tag only marks history. |
| `addFileLink` | `true` | Adds the "Original file" and "Find Scan" links |
| `attachScan` | `true` | Attaches the PDF to the note. `false` makes link-only notes, which keeps Notes lighter. |
| `scannedBy` | the author's name | Name used in the "Scanned by" line. **Change this.** |
| `addSummary` | `true` | Runs summarize-pdf for a summary |
| `summaryTool` | `"/usr/local/bin/summarize-pdf"` | Full path to the tool (`do shell script` uses a minimal PATH, so this must be absolute) |
| `summaryToolOptions` | `""` | Extra options for the tool, such as `"--always-add-summary"` |
| `findShortcutName` | `"Open Scan"` | Shortcut run by the "Find Scan" link. It must match the shortcut's name exactly. |

## How summarize-pdf works

```
summarize-pdf [--dry-run] [--always-add-summary] [--no-cleanup] file.pdf
```

| Option | Effect |
|---|---|
| `-n`, `--dry-run` | Downloads, OCRs, and summarizes, then reports what it would change without writing anything |
| `-s`, `--always-add-summary` | Also stores the summary in PDFs that already have text (this rewrites the file, so its modification date changes) |
| `-C`, `--no-cleanup` | Skips the black-and-white page cleanup (see below) |
| `-h`, `--help` | Shows usage |

The summary is the only thing printed to standard output. Everything else goes to standard error with a `DEBUG:` prefix, so callers can discard it with `2>/dev/null`.

### Steps

1. **iCloud download.** If the file is an iCloud placeholder (offloaded by Optimize Mac Storage), the tool asks iCloud to download it and waits up to two minutes.
2. **Text extraction.** It reads the PDF's text layer. If there's essentially none (fewer than 20 characters), it renders each page at about 216 dpi and runs Vision text recognition. Every page is OCR'd when a text layer will be added, but only the first five pages are used for the summary.
3. **Summary.** The text is wrapped in a short English prompt. Receipts and forms are mostly numbers, and without real sentences the model's language check can fail. The first attempt sends about 2,500 words, which fits the on-device model's roughly 4,096-token window. If the model reports the text is too long, it retries with 6,000 characters and then 3,000.
4. **Guided output.** Summaries are generated into a Swift struct (`@Generable`), which keeps the model from adding chatty openers like "Sure! Here is a summary" or markdown titles.
5. **Sensitive documents.** If the default safety filter declines (common with tax returns and other documents full of account numbers), the tool retries with Apple's permissive content-transformation mode, which is meant for summarizing text you already have. That mode only produces plain text, so the tool strips any preamble or formatting, and it prefixes the result with `Potentially sensitive:`.
6. **Writing back.** For image-only scans, the tool writes a new PDF with the original page images plus an invisible text layer placed over the recognized words, and stores the summary in the PDF's **Subject** field. The new copy must open and have the same page count and real text, or the original is left untouched. It then replaces the original, keeping its creation date, Finder tags, and permissions. PDFs that already have text are never modified unless `--always-add-summary` is given.

**Black-and-white cleanup.** When an image-only scan is rewritten, each page that is mostly black and white (under 1.5% colored pixels and under 25% mid-gray, so photos and color pages are skipped) is converted to grayscale with the paper brightened to white and the ink darkened. This is on by default; use `--no-cleanup`, or set `cleanUpBlackAndWhite` to `false` in the source, to leave page images untouched. PDFs that already have text are never cleaned up, since they aren't rewritten. `--dry-run` reports how many pages would be cleaned.

The text layer lets Spotlight, Preview's search, and text selection work on scans. The Subject field is visible in Preview under **Tools → Show Inspector**, and Spotlight indexes it.

### Exit codes

| Code | Meaning |
|---|---|
| 0 | Success. The summary was printed. |
| 1 | No text in the PDF, even after OCR (blank or unreadable), or the PDF couldn't be opened |
| 2 | Model error, or still too long after every fallback |
| 3 | The model declined even in permissive mode |
| 4 | The model couldn't identify the document's language (usually a numbers-only receipt or poor OCR) |
| 5 | Timed out waiting for iCloud to download the file |
| 64 | Usage error (missing file, more than one file, or unknown option) |

A text layer can still be added when the summary fails, since OCR happens first.

### Settings in the source

These are `let` constants near the top of `summarize-pdf.swift`. Changing one means rebuilding the tool.

| Constant | Default | Purpose |
|---|---|---|
| `maxWords` | `2500` | First-attempt word budget. Lower it to 2,000 if first attempts often fail as too long. |
| `fallbackCharLimits` | `[6000, 3000]` | Shorter retries, in order |
| `addTextLayer` | `true` | Set to `false` to never modify PDFs |
| `maxOCRPagesForSummary` | `5` | Pages of OCR text used for the summary |
| `minTextLayerCharacters` | `20` | Below this, a PDF is treated as image-only |

## Maintaining and updating

### Where each piece runs from

The files in this folder are the source of truth, but each piece runs from a different installed copy. After editing a source file, re-install it:

| You changed | Re-install by |
|---|---|
| `summarize-pdf.swift` | Rebuild and install ([step 1](#1-build-and-install-summarize-pdf)), then run `summarize-pdf --dry-run file.pdf` to check it |
| `importscan.applescript` | Open the Quick Action in Automator, replace the Run AppleScript contents (`pbcopy < importscan.applescript`), click the hammer, and save |
| The Open Scan shortcut | Edit it in the Shortcuts app, then update the script in [step 3](#3-create-the-open-scan-shortcut) of this README, which is the only written copy of it |

Automator and Shortcuts keep their own copies, so edits made there never come back to this folder by themselves. To check that `importscan.applescript` still matches the installed Quick Action, run this from this folder. It prints any differences, and no output means they match:

```
WORKFLOW="$HOME/Library/Services/Import Scans to Notes.workflow"   # use the name you saved it under
diff <(plutil -extract actions.0.action.ActionParameters.source raw -o - "$WORKFLOW/Contents/document.wflow") importscan.applescript
```

### How the pieces talk to each other

These are the links that break if one side changes without the other:

- **AppleScript → tool.** The script runs `summaryTool summaryToolOptions "file" 2>/dev/null` and puts whatever the tool prints to **stdout** into the note as the summary. A non-zero exit code or empty output means "no summary." So the tool must print nothing else to stdout. Use `log()` (which writes to stderr) for any debugging output.
- **Tool → file.** The tool may replace the PDF on disk, so anything that records the file's identity (the file ID link) must be built after it runs. The script already does this.
- **AppleScript → shortcut.** The "Find Scan" link is `shortcuts://run-shortcut?name=<findShortcutName>&input=text&text=<filename>`, URL-encoded. Open Scan receives only the filename text. Renaming the shortcut requires changing `findShortcutName` to match.
- **Names.** The AppleScript uses the title "Import Scans to Notes" in its skipped/failed notification, and the Swift file's header comment refers to the script by that name. The Quick Action's saved name doesn't matter to the code.
- **Docs.** Options, exit codes, and settings are documented in three places: the header comment in `summarize-pdf.swift`, the comments in `importscan.applescript`, and the tables in this README. Update all of them together.

### Testing a change

Test on copies of PDFs, since the tool rewrites image-only scans and the script tags files.

1. **Tool, from Terminal.** Run `summarize-pdf --dry-run copy.pdf; echo $?` against each of these and compare with the [exit code table](#exit-codes):
   - an image-only scan (expect OCR, then a summary)
   - a PDF that already has text (expect "PDF left unchanged")
   - a numbers-only receipt (may exit 4)
   - a blank page (exit 1)
   - an iCloud-offloaded file (expect a download first)
2. **Real write.** Run without `--dry-run` on a copy of an image-only scan, then open it in Preview and check that search works and the Subject field has the summary.
3. **Quick Action.** Temporarily set `notesFolderName` to a test folder in Notes, run the action on a copy, and check the note's text, links, and attachment. Switch it back afterward.
4. **Find Scan link.** Click it in the test note and confirm the file opens.

### After a macOS or Xcode update

- Rebuild and reinstall `summarize-pdf` ([step 1](#1-build-and-install-summarize-pdf)). Apple's `FoundationModels` framework is new, so a build error mentioning it usually means an API changed.
- Check that summaries still work. If the model's context window changes, adjust `maxWords` and `fallbackCharLimits`.
- If Open Scan stops working, recheck **Allow Running Scripts** in Shortcuts settings and the permissions in [step 4](#4-grant-permissions).

### Setting up a new Mac

Clone this repository and repeat [Installation](#installation). Create the Scans folder in Notes first. The Open Scan shortcut has to be re-created by hand from step 3, and you may want to export it from the Shortcuts app and keep that file with this repository.

## Troubleshooting

**A scan appears twice in its note.** This is a long-standing Notes display bug with attachments added by script. The second copy is an empty placeholder, not a real attachment. Click just after the last attachment and press Delete. It stays fixed after that. Automating this by sending keystrokes requires Accessibility access for Automator Workflow Runner, so it isn't included.

**Automator error -212.** The Run AppleScript action contains something that isn't AppleScript, such as the Swift source pasted by mistake. Check that the file you copied starts with `use AppleScript version`.

**The action isn't in Finder's right-click menu.** Make sure the workflow was saved in `~/Library/Services` and is set to receive PDF files in Finder. Right-click a PDF, open **Quick Actions → Customize…**, and check that it's turned on.

**`install: /usr/local/bin/: No such file or directory`.** Run `sudo mkdir -p /usr/local/bin` first, then repeat the install command.

**The build fails or can't find `FoundationModels`.** The macOS 26 SDK is missing. Check with `xcrun --show-sdk-version` (it should be 26 or later), and update Xcode or the Command Line Tools.

**No summary in the note.** Run the tool by hand to see why: `summarize-pdf file.pdf; echo $?` and check the exit code table. Common causes are a refused or unreadable document, or the tool not being at the path in `summaryTool`. Exit code 2 with a DEBUG line about the model being unavailable usually means Apple Intelligence is off or hasn't finished downloading.

**"Unsupported language."** The document is mostly numbers or the OCR is garbled. Exit code 4. The note is created without a summary.

**The Find Scan link says "Not found".** The file was renamed, or it's outside the folders listed in `roots`. Add the folder to `roots` in the Open Scan shortcut.

**The Find Scan link does nothing.** The shortcut's name doesn't match `findShortcutName` exactly, or Allow Running Scripts is off in Shortcuts settings.

**The Original file link doesn't open.** File ID links only work on the Mac where the note was created, and only while the file stays on the same drive. On other devices, use the attached PDF or search Notes.

## Files

```
macutils/
├── LICENSE                     MIT
└── notesimport/
    ├── README.md               This document
    ├── importscan.applescript  Source for the Quick Action's Run AppleScript action
    └── summarize-pdf.swift     Source for the command-line tool
```

Not in this repository: the installed Quick Action (`~/Library/Services`), the compiled `summarize-pdf` binary, and the Open Scan shortcut, which is described in step 3 above. If the Mac is replaced or Xcode updates break the build, the sources and instructions here are enough to rebuild everything.
