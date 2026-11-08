# redact_names

A macOS command-line tool that blacks out student names on scanned work.
**Everything runs on this Mac.** No cloud APIs. The only network call is the optional
`--verify` step, which talks to an Ollama server on `localhost`.

## Build

```sh
swift build -c release
```

The binary is `.build/release/redact_names`. Requires macOS 13+ and Swift 5.9+
(the first build downloads `swift-argument-parser`).

## Run

```sh
# 1. Check box placement first: red outlines, nothing blacked out
.build/release/redact_names ~/Scans/quiz3 --preview

# 2. Real run -> writes ~/Scans/quiz3_redacted/
.build/release/redact_names ~/Scans/quiz3

# 3. Belt and braces: roster matching, fallback, and a local-LLM check
.build/release/redact_names ~/Scans/quiz3 --roster roster.txt --fallback-top 0.15 --verify
```

Input can be a **folder** or a **single file** (PDF / PNG / JPG / TIFF).

- Folder: output goes to `<input>_redacted/` next to it, same file names, plus `review_log.csv`.
- File: output is `<name>_redacted.<ext>` next to the original, plus `<name>_review_log.csv`.

```sh
redact_names ~/Scans/quiz3/jordan.pdf --preview
```

| Flag | Default | Meaning |
|---|---|---|
| `--preview` | off | red outlines instead of black fill |
| `--roster <file>` | | one name per line; also blacks out any OCR line containing a roster word |
| `--fuzzy <0-1>` | 0.85 | roster match threshold (1 = exact) |
| `--pad <n>` | 1.5 | vertical padding above the name, in line heights |
| `--margin <px>` | 8 | extra pixels around each box |
| `--fallback-top <f>` | off | if page 1 has no `Name:` label, black out this top fraction |
| `--dpi <n>` | 200 | PDF render resolution |
| `--no-auto-names` | off | turn off the name-like-word detection described below |
| `--scope <s>` | page | `page`: the Name: label plus name-like words anywhere. `header`: **only the top of each page**; the body is never touched (see below) |
| `--header-fraction <f>` | 0.22 | with `--scope header`: the top fraction of each page that counts as the header |
| `--name-pages <p>` | first | which pages are searched for a Name: label: `first` or `all` (`--scope header` always uses `all`) |
| `--name-extent <e>` | width | `width`: one black strip across most of the page, keeping the side margins (the surest). `stop`: stop at the next printed label (Date, Period...). `edge`: to the page edge |
| `--side-margin <f>` | 0.05 | with `width`: fraction of the page width left clear on each side |
| `--name-lines <n>` | 1 | also cover this many rows directly below the Name line (0 = none); names often wrap |
| `--no-infer-name-area` | off | turn off copying the Name area onto pages where the label wasn't found (see below) |
| `--fill <style>` | black | how redactions look: `black` (slightly rounded corners), `gray`, `white`, or `label` (light gray with the word REDACTED). All remove the pixels completely |
| `--mode <m>` | standard | `standard` or `aggressive` name detection (see below) |
| `--explain` | off | print each flagged word and why (shows scan text; use on practice files) |
| `--verify` | off | ask a local Ollama model whether a name is still visible |
| `--model <name>` | qwen3-vl:8b | model for `--verify` |

`review_log.csv` has `file,page,status`. A page is flagged `CHECK` if page 1 has no
`Name:` label or if `--verify` reports a visible name. **Look at every CHECK page.**
Student names are never written to the CSV.

## The Name line, and header-only mode

By default the Name line is covered by **one black strip across most of the page** (the side margins stay
clear), from above the Name line to below the row after it. Nothing depends on guessing where the handwriting
ends, so a long or loopy name can't stick out the right side, and a first and last name that wrap onto two
lines are both covered. The strip's top and bottom edges snap around printed lines: a printed line is either
covered completely or left alone, never sliced in half. The cost is that a printed line right under the Name
line (such as a "Topic:" line) is usually covered with it. Use `--name-lines 0` to cover the Name line only.

**When OCR misses the label.** A bold printed "Name" with handwriting jammed against it is often misread. Two
safety nets cover that:

1. The label match is forgiving: "Nome", "Narne" (the classic "rn" for "m"), and "Name" glued to a scribble
   are all accepted.
2. If the label was found on **more than half** of the pages that were searched (every page in `--scope header`
   or with `--name-pages all`), the handout is the same printed form on every sheet, so the Name area is in the
   same place. That area (the median position) is **copied onto the pages where the label wasn't found**. The
   review log marks them `OK (name area copied from other pages)`. A back side with no name gets the same strip;
   that costs you its top margin but never leaks a name.

If there are too few pages to infer from, or half or fewer had the label, a page with no label is flagged
`CHECK: no Name: label on this page, but other pages had one`, so it never passes quietly.

`--name-extent stop` gives a tighter band that stops at the next printed label (`Date:`, `Period:`), keeping
those visible, and `--name-extent edge` runs from the label to the page edge. Both still cover the row below,
placed by geometry rather than by what OCR found, because OCR often fails to read handwriting.

**Look of the redaction.** Black with slightly rounded corners is the default. `--fill label` draws a light gray box with the word REDACTED, `--fill gray` a plain
light gray box, `--fill white` blanks the area. They remove the pixels just as completely as black does, so they
are equally private; the gray styles are easier on the eye and tell a reader (or a model) what happened.
Blurring would be gentler still but is not safe: a mild blur can often be partly undone.

For class PDFs where every sheet has a name at the top, and you don't want the body touched:

```sh
redact_names class.pdf --scope header
```

This looks for `Name:` on **every** page (not just the first) and redacts only inside the header: the
Name band, plus name-like words and roster names that appear in the top of the page. Nothing lower on the
page is touched, so names in a "who said it" column survive. A page with no `Name:` label is left alone
(it's probably a back side), unless name-like text appears at the top, which is flagged `CHECK`.
Use `--header-fraction` if your headers are taller or shorter.

## Names outside the `Name:` label

Student names also show up elsewhere (a "who said it" column, a lab partner, a signature).
So every page is scanned for words that *look like* names, by several independent signals.
Any one is enough, and the tool prefers to over-redact:

**`--mode standard`** (default) uses signals 1 and 2. **`--mode aggressive`** adds 3 and 4.

1. **Name list.** About 30,000 first names and common surnames are compiled into the binary
   (built from public SSA and Census data by `tools/make_name_data.swift`). Names that are also
   ordinary words ("mark", "grace", "baker") only match when Capitalized.
2. **Apple's `NLTagger`**, an on-device model that spots personal names in context.
3. *(aggressive)* **Capitalized + not an English word** (per the macOS spell checker): "Atticus", or a misread name.
4. *(aggressive)* **Two or more Capitalized words in a row**: "Scout Finch".

Only the flagged *word* is blacked out, not the whole line, so the rest stays readable.

## How it works

1. Each page becomes a bitmap (PDFs are rendered at `--dpi`).
2. Vision (`VNRecognizeTextRequest`, `.accurate`) reads the text lines.
3. On page 1, find the `Name:` label near the top. The box covers everything to its right,
   up to the next label on that row (Date, Period, Class...) or the page edge. If Vision
   merged label and handwriting into one line, `VNRecognizedText.boundingBox(for:)` measures
   the exact text after the label.
4. Boxes are drawn onto the bitmap and the pages are written out as pictures, so
   **no text layer survives** in output PDFs.

## Source map

| File | Job |
|---|---|
| `RedactNames.swift` | command-line flags, folder loop, summary |
| `Redactor.swift` | decides what to black out on a page |
| `NameDetector.swift` | the name-like-word signals above |
| `NameData.swift` | generated name list (`tools/make_name_data.swift` rebuilds it) |
| `NameFinder.swift` | finds `Name:` and computes the band |
| `RosterMatcher.swift` | Levenshtein fuzzy matching |
| `OCR.swift` | Vision wrapper |
| `Geometry.swift` | **coordinate conversions** (Vision is bottom-left, normalized) |
| `PageIO.swift` | load pages, draw boxes, write flattened output |
| `OllamaVerifier.swift` | optional local-LLM check |
| `ReviewLog.swift` | `review_log.csv` |

## Tests and samples

```sh
swift test                          # coordinate conversion + Levenshtein
swift samples/make_samples.swift    # regenerate the fake worksheets in samples/
```

The samples use invented names only.

## Limits

- Handwriting OCR is imperfect. Always run `--preview` on a few scans and read the CHECK pages.
- Everything depends on OCR *reading* the handwriting. If Vision cannot read a name, no rule
  above can catch it. That is the main way a name survives.
- Names that are also common English words (Scout, Grace, Hope) are the other weak spot;
  signals 2 and 4 and `--aggressive` help.
- Over-redaction is expected ("Hope", "Green", a Capitalized title). That is deliberate.
- Roster matching works on single words of 3+ letters, so it can over-redact a common word
  that is also someone's name. That is the intended failure direction.
