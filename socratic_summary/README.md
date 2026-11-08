# socratic_summary

Summarizes scanned Socratic seminar work, **entirely on this Mac**. Give it one PDF per class and,
optionally, the lesson plan. It writes a Markdown summary, in this order:

1. how the seminar went as a whole, and how students' thinking shifted (and, if you merge classes,
   how the classes compared),
2. where students started and where they ended up,
3. **where students stood**: how many held each of the lesson's positions at the start and end, and who moved,
4. what influenced their thinking, and **ideas shared by several students** (counts, who, an example quote),
5. **evidence of learning and goals**: what went well and where there is room to grow, goal by goal,
6. caveats, then a private **student key** (Student 3 = Maria G.) at the very end.

Names are hidden in the body ("Student 3"). Nothing leaves the Mac: the only network traffic is to
Ollama on `localhost`.

## Requirements

[Ollama](https://ollama.com) running locally, with:

```sh
ollama pull qwen3-vl:8b-instruct   # reads handwriting. Do NOT use the "thinking" build: minutes per page
ollama pull gemma2:27b             # groups ideas and writes the summary (best installed model that fits 32 GB)
```

The tool checks that these are installed before doing any slow work.

## Build and install

```sh
swiftc -O -parse-as-library socratic_summary.swift -o socratic_summary
sudo install -m 755 socratic_summary /usr/local/bin/
```

## Use

```sh
# One PDF per class, with the lesson (the usual run)
socratic_summary period3.pdf --class "Period 3" \
    --lesson ~/src/macutils/attic/lesson.md --lesson ~/src/macutils/attic/kit.md

# Same class, two PDFs (entry tickets and exit tickets scanned separately)
socratic_summary entry.pdf exit.pdf --class "Period 3" --lesson lesson.md
```

Output goes to files in the current folder, not the screen:

| File | What |
|---|---|
| `<class>_summary_gemma2-27b.md`, `<class>_summary_llama3.1-8b.md` | the summary, once per summary model, from the same reading |
| `<class>.data.json` | the detail data: one record per page. **Contains names; keep private.** |

With one `--summary-model`, the file is simply `<class>_summary.md`. Add `--stdout` to also print.
**The summary files end with a student key** (number → name). Delete it before sharing, or use `--no-key`.

### Comparing summary models

The default summary model is `gemma2:27b`: on real student pages its themes were about the students' *reasons*,
while `llama3.1:8b` labeled themes by position, which contradicted the circled counts. To compare anyway, name
two: `--summary-model gemma2:27b,llama3.1:8b` (each writes its own file from the same reading).

### The lesson

`--lesson` takes the lesson plan and/or the facilitation kit (`.md .txt .html .rtf .docx .pdf`, or a
folder). It is distilled once into a brief: the central question, **the positions**, **the learning
goals**, and what meeting each goal looks like. That brief is given to the reader and the summary, so:

- each student's start and end are sorted into the lesson's actual positions (exact counts and a
  start → end movement table, computed in code, not by the model);
- each page is rated per goal as *specific* (it has the concrete detail the criterion names, such as a
  cited paragraph or a named rule), *vague*, or *none* (or *not asked* if the page has no prompt for it),
  then tallied per goal. There is **no grade**. Goals are listed as **what went well**, **coming along**,
  **room for improvement**, and **not captured on these sheets**, with the counts in a table.

The narrative paragraphs are written in words only ("most", "several", "a few"). Exact counts live in the
tables, because small models misquote numbers. Any sentence that still contains a digit is dropped.

If the digest gets the positions wrong, set them yourself: `--position "Buy it" --position "Don't"`.
The brief is saved in the data file, so re-runs and merges don't need the lesson files.

**This is a gauge, not an assessment.** It reflects only what students wrote, as read by a model; it does
not see the live discussion or the observer organizers' tallies, and a goal that looks weak may simply not
have been asked about on the sheet. Check the per-goal table and the example quotes.

### How a page is read (what happens per page)

1. **Transcribe** with the vision model (`qwen3-vl:8b-instruct`).
2. **Which option is circled?** If the lesson (or `--position`) names positions, the page is cropped around the printed
   options and the vision model is asked only that, so it reads the pen marks, not the writing. Two circles are
   reported as two (and counted as "unclear").
3. **Apple OCR of the printed form**, used only to tell fronts from back sides.
4. After all pages are read: lines that repeat on most pages (the printed form) are removed, each page is analyzed from
   its own answers, and every idea must be made of the student's own words (anything else is dropped).

A page never counts as "illegible" because of the model's say-so: it counts if it has text.

### Big PDFs, interruptions, and back sides

- Pages are rendered one at a time, so a whole class in one PDF is fine.
- Progress is saved after every page and logged with a time estimate. If a run is interrupted,
  `--resume` continues from the data file.
- A page that takes longer than 5 minutes (`--timeout`) is counted as unreadable, and the run continues.
- Only pages with student writing count as students. Blank or printed-only pages are left out and reported.
- Pages whose written names match are the same student. An unnamed page joins the student before it only if it
  **looks like a back side**: it contains little of the printed form the other pages share (judged from Apple OCR),
  and each student gets at most one back. Identical fronts are never merged. With fewer than 4 pages there is no way
  to tell, so nothing is merged (use `--pages-per-student 2` for a front-and-back scan). `--no-attach-backs` turns it off.

### Re-running and merging classes

```sh
socratic_summary --from-notes period3.data.json --names           # same data, names shown in the body
socratic_summary --from-notes period3.data.json --from-notes period5.data.json   # merge classes
```

Merged summaries add per-class counts to every theme (`[Period 3 5/12, Period 5 3/9]`), per-class
position tables and goal scores, and a "How the classes compared" paragraph. Students stay separate
between classes. Reading handwriting is the slow part; summarizing from a data file takes minutes.

### Two ways to read handwriting

| | `--reader vlm` (default) | `--reader vision` |
|---|---|---|
| How | a local vision model looks at each page image | Apple's on-device Vision OCR, then a text model structures it |
| Speed | many seconds to about a minute per page | fast OCR (a second a page) |
| Messy handwriting | better | weaker |
| Tables/columns | understands layout | flattened to lines of words |

Use `--max-pages 3` to try either reader on a few pages first.

## All options

`--class`, `--lesson` (repeatable), `--position` (repeatable), `--names`, `--no-key`, `--model`,
`--summary-model A[,B]`, `--reader vlm|vision`, `--output`, `--data`, `--stdout`, `--resume`,
`--from-notes` (repeatable), `--pages-per-student N`, `--no-attach-backs`, `--one-student-per-pdf`,
`--topic`, `--strip-names`, `--max-pages N`, `--timeout SECONDS`. Run `socratic_summary --help`.

## Limits

- Everything depends on the model reading handwriting correctly. Spot-check against the originals.
  Each page's verbatim transcript is saved in the data file (`handwriting`); open it next to the paper.
- Reading is two steps: the vision model only **transcribes** each page, then a text step derives the
  fields, positions and goal ratings from the transcript. (One combined prompt made the vision model
  read the name and leave everything else empty.) `--reclassify` redoes the second step from saved
  transcripts without re-reading.
- Positions and goal ratings are per-page model judgments; the counts are tallies of those.
  Theme groupings are the summary model's judgment. Use counts as a guide.
- Anonymizing replaces names found on the sheets (including classmates mentioned inside other sheets).
  A teacher's name, a character in the reading, or a classmate with no sheet is not replaced.
- **Use the right lesson.** If the lesson's positions appear on almost none of the pages, the tool warns
  ("looks like the WRONG LESSON") and ignores the lesson. You can always give the positions yourself with
  `--position "On by default" --position "Off by default" --position "Ask each owner"` and no lesson file.
- Tested on 15 real (redacted) handwritten entry tickets: the reader recovered about 96% of the words I checked by
  eye, and read the circled option correctly on every clearly marked page. Weak spots: a row scribbled out instead of
  circled, very faint writing, and the occasional page where the vision model loops (it then falls back to Apple OCR).
- Student work and lesson folders such as `attic/` are gitignored. The data file and the summary's
  student key contain names, so do not commit, email, or sync them anywhere shared.

## Testing without real student work

```sh
swift make_test_sheets.swift      # three PDFs of six invented students
socratic_summary test_start.pdf test_after.pdf --lesson test_lesson.md
```
