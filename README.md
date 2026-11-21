# Copy 4 AI (cp4ai)

## 1. Intro

Copy 4 AI turns `.docx`, `.pdf` and `.pptx` files into Markdown that is ready
to paste into ChatGPT, Claude or any other AI chat.

It is **recall-first**: every word in the source matters. OCR mistakes,
duplicate text and imperfect formatting are acceptable because the AI can
interpret them; silently dropping a sentence or a table row is not.

Copy 4 AI gives you four ways to work:

- **Copy 4 AI** — a Finder Service that converts files and copies the
  result to the clipboard.
- **Copy 4 AI (no OCR)** — the same service without reading text from images,
  useful when the files already have a good text layer.
- **`cp4ai`** — the clipboard workflow from a terminal.
- **`md4ai`** — the same conversion, written to `.md` files instead.

It keeps headings, lists, tables, footnotes, comments, speaker notes, page and
slide boundaries, and text found inside images. Everything runs locally:
files are never uploaded, and there is no account or network requirement.
You do not need Python, Homebrew, Tesseract or any other extra software.

Released under the MIT License. Bundled third-party components are listed in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## 2. Setup

### Requirements

- Apple Silicon Mac
- macOS 15 or later

### Install

1. Download `Copy4AI-3.2.0-arm64.dmg` from the official release page.
2. Open the DMG, drag **Copy 4 AI.app** to Applications, then eject the DMG.
3. Open **Applications** and double-click **Copy 4 AI**.
4. macOS will say it cannot verify the app. Click **Done**; do not choose
   **Move to Trash**.
5. Open **System Settings** → **Privacy & Security**.
6. Scroll to **Security** and click **Open Anyway** next to the Copy 4 AI
   message.
7. Enter your Mac password or use Touch ID, then click **Open** (or **Open
   Anyway**) if macOS asks again.
8. Click **OK** on the welcome dialog.

This is only needed once. On macOS 15 and later, right-click → **Open** does
not bypass this warning. If **Open Anyway** is not visible, double-click the app
again and return to Privacy & Security; the button appears only after macOS has
blocked the app.

The app is ad-hoc signed, so Apple has not notarized it. That is why the
warning appears; it does not mean the app is damaged. Do not disable macOS
security settings. Running the app directly from the mounted DMG also shows a
warning; install it in Applications first.

That first launch does the rest:

- registers **Copy 4 AI** and **Copy 4 AI (no OCR)** in Finder > Services;
- installs `~/.local/bin/cp4ai` and `~/.local/bin/md4ai`;
- adds `~/.local/bin` to your `PATH` in `~/.zprofile`.

Open a new terminal after this if you want to use the command-line tools.

The welcome dialog is shown whenever you double-click the app. It is only a
reminder; the app has no main window. In Finder, the commands are under
**Finder > Services**.

### If Finder does not show the Services

Launch the app once, then relaunch Finder. You can also refresh the Services
database manually:

```bash
/System/Library/CoreServices/pbs -flush
```

### Update

Quit the app, replace it in Applications with the new version, and open it
once. The Services, command-line links and PATH entry are refreshed
automatically. If macOS warns again after the replacement, repeat the
**Open Anyway** steps above; that is normal for a newly downloaded app.

### Uninstall

```bash
rm -rf "/Applications/Copy 4 AI.app"
rm -f "$HOME/.local/bin/cp4ai" "$HOME/.local/bin/md4ai"
```

Then remove the block marked `Copy 4 AI command-line tools` from
`~/.zprofile`. The Finder Services disappear after Finder refreshes its
Services list.

### Build from source

Requirements: Xcode, [XcodeGen](https://github.com/yonaskolb/XcodeGen),
`create-dmg`, `uv` and Python 3.

```bash
brew install xcodegen create-dmg
./packaging/build_app.sh
```

The script fetches Pandoc, librsvg and libemf2svg, builds the PyMuPDF helper
with PyInstaller, generates the Xcode project, builds the Release app, signs it
ad-hoc and writes:

```text
dist/Copy4AI-3.2.0-arm64.dmg
```

For core tests:

```bash
swift test --package-path Packages/CP4AICore
```

Logs are written to `~/Library/Logs/Copy 4 AI.log`.

## 3. Usage

### Finder Services

1. Select one or more `.docx`, `.pdf` or `.pptx` files in Finder.
2. Right-click → **Services**.
3. Choose **Copy 4 AI** (read text from images too) or **Copy 4 AI (no OCR)**
   (faster; images are skipped).
4. When the progress panel finishes, paste into your AI chat.

Each file is wrapped in markers so the AI can tell documents apart:

```text
[a.pdf BEGIN]
...
[a.pdf END]

[b.docx BEGIN]
...
[b.docx END]
```

Multiple selected files are deduplicated and converted in case-insensitive
filename order. The wrappers exist only in clipboard output; `md4ai` files do
not contain them.

The clipboard is only changed when every file succeeds. Errors stay in the
progress panel, and details go to the log. Directories are not accepted; select
files instead.

### `cp4ai` — clipboard

```bash
cp4ai                          # print help; no GUI is opened
cp4ai a.docx b.pdf             # convert and copy the combined result
cp4ai --no-ocr a.pdf           # skip OCR
cp4ai --jobs 4 notes/*.pptx    # four workers
cp4ai --languages en-US,zh-Hans slides.pptx
```

On success it prints:

```text
=========================
Copied to clipboard! (26524 characters / 5980 tokens)
```

`characters` counts the Unicode scalars in the complete clipboard text;
`tokens` are exact `cl100k_base` tokens. Duplicate paths are ignored. Documents
are concatenated in argument order. `cp4ai` accepts files only; directories,
missing paths and unsupported types are rejected before conversion. If any file
fails, the clipboard is left untouched and the command exits with a non-zero
status.

| Option | Meaning |
| --- | --- |
| `--no-ocr` | Do not read text from images |
| `--jobs N` | Parallel workers (default: all active CPU cores) |
| `--languages LIST` | OCR languages, comma separated (default: `en-US`) |
| `-h`, `--help` | Show help |
| `--version` | Show the version |

### `md4ai` — Markdown files

```bash
md4ai a.pdf                    # writes a.pdf.md next to a.pdf
md4ai a.docx                   # writes a.docx.md
md4ai -r notes/                # every supported file under notes/
md4ai -rf notes/               # recursive, overwrite existing .md
md4ai -o b.md a.pdf            # write exactly b.md
md4ai -o out/ -r notes/        # preserve the tree under out/
md4ai --no-ocr scanned.pdf
```

Output names never collide with the source: `name.pdf` becomes
`name.pdf.md`, and the same pattern applies to DOCX and PPTX. Existing
outputs are refused unless `-f/--force` is given, duplicate output paths are
rejected, and every destination is checked before any file is written.
Recursive scans skip hidden files and Office lock files beginning with `~$`,
sort inputs by case-insensitive path and print result lines in that order.
If one input fails, the other documents are still written; the command
reports each failure and exits non-zero.

| Option | Meaning |
| --- | --- |
| `-r`, `--recursive` | Convert every supported file under a directory |
| `-f`, `--force` | Overwrite existing Markdown |
| `-o`, `--out` | Output file, or directory preserving the input tree |
| `--no-ocr` | Do not read text from images |
| `--jobs N` | Parallel workers (default: all active CPU cores) |
| `--languages LIST` | OCR languages, comma separated (default: `en-US`) |
| `-h`, `--help` | Show help |
| `--version` | Show the version |

`-rf` and `-r -f` are equivalent. Directory input requires `-r`, and `md4ai`
takes one target per run; extra positional targets are ignored. No target
prints help. For `-o`, an existing directory, a path ending in `/`, or a path
whose extension is not `.md` is treated as a directory; otherwise it is a
file. When the target is a directory, `-o` must resolve to a directory.

### What the Markdown contains

Front matter is always first. Common keys are `source` (working-directory
relative when possible), `format` and `converted`. Format-specific keys are:

- DOCX: `converter`, `header` when a substantive Word header exists,
  `comments` when there are comments, `images_ocr`.
- PPTX: `converter`, `slides`, `notes`/`comments` counts when non-zero
  (`notes` counts slides with notes; `comments` counts all comments),
  `images_ocr`.
- PDF: `pages`, `text_extraction`, `images_ocr`.

`format` is `docx`, `pdf` or `pptx`; `converter` is `pandoc <version>` and
`text_extraction` is `pymupdf <version>`. `format` is a plain token; every
other front-matter value is double-quoted and YAML-escaped. `converted` is the
local calendar date. `source` is relative to the current working directory when
possible and absolute otherwise. `images_ocr` is `disabled` under `--no-ocr`;
otherwise it is `Apple Vision (en-US)`, with the number of pages that received
OCR text for PDF. The body starts with `# <file stem>`; only the final
extension is removed, and whitespace runs in the stem are collapsed.

- PDF pages are marked `<!-- page N of M -->`; PPTX slides are marked
  `<!-- slide N of M -->`.
- DOCX comments follow the passage they annotate, with author and the first
  10 characters of the date. Comments with no text are omitted; unanchored
  comments go into an appendix.
- The first substantive Word header, excluding page-number-only headers, is
  emitted as `> **Original document header:** …`.
- PPTX speaker notes and comments follow their slide.
- DOCX images extracted to media but not referenced in the body go into a
  `## Figures from the original document (OCR text)` section in natural
  filename order. The section is omitted under `--no-ocr`.
- For DOCX, a `## Vector images (not OCR'd)` list is added if an EMF, WMF or
  SVG drawing cannot be rendered.

With OCR enabled, every located image file is passed to OCR. DOCX labels use
the alt text, falling back to the image filename; PPTX labels use the image
title, alt text, then filename. Other DOCX images and ordinary PPTX pictures
become blockquotes. DOCX/PPTX pictures in table rows, and inline DOCX `<img>` tags,
become inline `<br>**Image text (OCR) — …**` text; newlines become `<br>`, and
table text also escapes `|`.

PDF pages append one OCR warning comment and then all image blocks after the
native page text when at least one OCR block survives the filters. Each image
has its own blockquote with a page-relative position, for example:

```text
> **Image text (OCR) — image — [top: 6%, left: 8%, width: 83%, height: 31%]**
```

PPTX positions appear when the slide XML has a picture transform.

OCR text shorter than 10 non-whitespace characters is dropped entirely,
without a placeholder. Missing DOCX/PPTX image files get an `image not
extracted` comment. Under `--no-ocr`, DOCX/PPTX emit
`image omitted (OCR disabled)` comments for referenced images (PPTX also keeps
known positions), the DOCX unreferenced-image figures section is omitted, and
PDF output contains only its native text.

Image files themselves are never copied into the Markdown.

## 4. Design / Algorithm

### Architecture

```text
Copy 4 AI.app
├── Copy 4 AI          AppKit Services handler + progress panel
├── cp4ai              CLI (also invoked as md4ai)
└── Contents/Resources
    ├── bin/           pandoc, rsvg-convert, emf2svg-conv + dylibs
    ├── pdf-helper/    PyInstaller bundle: PyMuPDF + layout model
    ├── tiktoken/      cl100k_base vocabulary
    └── fonts.conf
```

The Swift app and CLI share `CP4AICore`. The app is a native Finder service:
it declares two `NSServices` entries and shows only the floating progress
panel. There is no document window and no sandbox, because the app launches
Pandoc, the PDF helper and the vector converters.

Python is used for one job only: a small PyInstaller helper reads PDFs with
PyMuPDF and returns page Markdown plus per-image placement PNGs. Swift does
all OCR, text merging and Markdown assembly.

### DOCX

1. Pandoc converts the document to GitHub-flavored Markdown with `--wrap=none`,
   ATX headings, `--track-changes=all` and `--extract-media`. This preserves
   headings, lists, tables, footnotes, text boxes and tracked changes.
2. Every Markdown image link and raw `<img>` tag is replaced by the OCR text.
   Labels use the alt text, falling back to the image filename. Table cells
   get inline OCR; standalone images become blockquotes; inline `<img>` tags
   stay inline. Inline and table text replaces newlines with `<br>`; table
   text also escapes `|`, and inline DOCX `<img>` OCR text is HTML-escaped.
   Identical image data is OCR'd once per document and reused at every
   placement.
3. Every image extracted to the media directory but not referenced in the body
   is OCR'd into a `## Figures from the original document (OCR text)` section
   in natural filename order. Each entry is headed
   `### Figure N — <filename>`. Only results with at least 10 non-whitespace
   characters are included. Under `--no-ocr` this section is omitted.
4. `word/comments.xml` and `word/document.xml` are parsed in Swift. Comments
   are placed after the passage they annotate, ordered by their first anchor
   in the document; comments in table cells stay inline; unanchored comments
   go into an appendix. Empty comments are omitted. Dates keep the first 10
   characters. Anchors are truncated at 400 characters in block/appendix
   comments and 200 characters inline. Multi-paragraph comment text keeps its
   paragraph breaks. Block comments are numbered `Comment N — author — date`
   in document order. Only anchors present in `word/document.xml` are found;
   comments anchored only in headers or footnotes go into the appendix.
5. The first substantive header in lexicographic `word/headerN.xml` order is
   emitted in front matter and as an `Original document header` blockquote.
   Its paragraphs are joined with spaces. Headers whose only text is `PAGE` or
   `PAGE <number>` are ignored.
6. Unusual images are rasterised before OCR:
   - EMF+ bitmap records are read directly from the EMF file in Swift, their
     BGRA/BGR pixels are alpha-flattened onto white and written as PNG;
   - an EMF with no usable EMF+ bitmap goes through `emf2svg-conv`, then
     `rsvg-convert`;
   - SVG goes through `rsvg-convert`;
   - WMF has no renderer and is reported as a vector image that was not OCR'd.
7. If rasterisation fails, a referenced vector image gets an inline
   `vector image not OCR'd` comment, and every failed vector filename is listed
   once under `## Vector images (not OCR'd)` in natural filename order.
8. The media directory is temporary and deleted afterwards.

### PDF

1. The PyMuPDF helper extracts the native text layer one page chunk at a time
   with layout enabled and its own OCR disabled.
2. Native page Markdown is normalised before use: `ff`, `fi`, `fl`, `ffi` and
   `ffl` ligatures expand; no-break spaces become spaces; soft hyphens are
   removed; ordinal brackets such as `1[st]` become `1st`; trailing spaces,
   tabs and carriage returns are trimmed from each line; runs of three or more
   newlines collapse to two; outer whitespace is trimmed.
3. Image discovery uses the PDF image objects, not layout inference. It scans
   the default layer state plus each checkbox/radio layer with a UI entry,
   hiding all layers and then enabling one at a time, and unions the visible
   placements. Bounding boxes are clipped to the page; placements 1 pt or
   smaller in either dimension are ignored. Placements are deduplicated by
   xref, bbox rounded to 0.1 pt and image digest.
4. A placement is skipped when a later-painted image completely contains its
   clipped bbox (0.5 pt tolerance) and is fully opaque. Fully opaque means no
   mask, or a soft mask whose bytes are all 255. Unknown and colour-key masks
   are treated as transparent, and PDF graphics-state transparency is not
   analysed. The rule is applied per layer state, so a lower image that is
   visible in another state is still kept.
5. A surviving placement that intersects another surviving placement in the
   same state is OCR'd from the raw image XObject so the crop cannot contain
   the other image; if that extraction fails it falls back to a page crop.
   Other placements are rendered from the page at 300 dpi. Positions use the
   clipped bbox.
6. If a page has no placements and fewer than 40 distinct native word tokens,
   the full page is rendered at 300 dpi for OCR. A token is a lowercase run of
   at least two ASCII letters or digits from `page.get_text()`; this catches
   vector-only pages whose text was converted to outlines.
7. Pages are marked `<!-- page N of M -->`. When at least one OCR block
   survives the filters, the page gets one OCR warning comment followed by one
   blockquote per surviving image. Placements are emitted in discovery order:
   default state first, then each isolated layer, with paint order inside a
   state. OCR is dropped when it has fewer than 10 non-whitespace characters
   or when the deduplication rule below matches the same page. Positions are
   page-relative integer percentages rounded to the nearest 1% and clamped to
   0–100%. Ordinary placements are labelled `image`; a full-page fallback is
   labelled `full page`.
8. Images that exist only as PDF annotations, and vector-only content on
   hidden layers, are outside image-object discovery. The full-page fallback
   uses the default layer state.

### PPTX

1. Pandoc converts the presentation to GitHub-flavored Markdown with
   `--wrap=none`, ATX headings and `--extract-media`; slide titles become
   level-2 headings.
2. Swift parses the PPTX XML for slide order, speaker notes, comments, slide
   size and picture coordinates. The slide count is the larger of the Pandoc
   `## ` chunk count and the presentation slide count. Markdown before the
   first `## ` is prepended to the first slide.
3. Slides are marked `<!-- slide N of M -->`.
4. Images are replaced by OCR text. Labels use the Markdown image title, then
   alt text, then the media filename. Pictures in pipe-table rows use inline
   text. Coordinates are read from each `<p:pic>` transform and stored under
   the picture name and media filename; replacement looks up the Markdown
   title, then the media filename. When a position is available it is appended
   as percentages rounded to the nearest 10% and clamped to 0–100%; rotation
   and flip are ignored. A normal picture gets a list item
   `- **Position:** [top: 45%, left: 60%, width: 40%, height: 20%]`; a picture
   inside a pipe table gets `<br>**Position:** [...]` inline. OCR text under
   10 non-whitespace characters drops the image and its position. A vector
   picture that cannot be rendered is dropped the same way as empty OCR text.
5. Speaker notes and comments are appended after their slide. Notes are under
   `### Speaker notes`; comments are under `### Comments`, each starting with
   `> **author — date**`. Notes are read from text shapes, skipping non-body
   placeholders; placeholder text `-` or `Click to add notes` is ignored.
   Comments show the author and the first 10 characters of the date; empty
   comments are omitted.

### OCR

OCR uses Apple's current Swift Vision API, `RecognizeTextRequest` (revision 3),
at accurate recognition level with language correction enabled.

- Images are composited onto a white RGB bitmap before recognition, so
  transparency does not hide text.
- Only the first candidate for each observation is used. Blank observations
  are discarded. Observations are sorted top-to-bottom using a 0.5% vertical
  tolerance, then left-to-right, and emitted one per line.
- The Finder Services use `en-US`. The CLI accepts `--languages` to add more,
  for example `en-US,zh-Hans`; the list is passed to Vision in order.
- Results are cached by a SHA-256 digest of the image data, so identical images
  are never OCR'd twice within one document.
- OCR shorter than 10 non-whitespace characters is dropped for every format.
  A raster image that cannot be decoded produces no text and is dropped by the
  same rule.

### Text-layer deduplication

PDF OCR is compared with the **same page's** native text layer after removing
all Unicode whitespace from both strings. OCR is discarded only when the
stripped OCR text is an **ordered subsequence** of the stripped native text:
every OCR character must appear in the native text in the same order, although
the characters do not need to be contiguous.

Case, punctuation and repeated characters still matter. For example, native
`the court may adjourn` and OCR `court adjourn` deduplicate because
`courtadjourn` is an ordered subsequence of `thecourtmayadjourn`. OCR
`adjourn court` does not deduplicate because the order is wrong.

For PDF, this check runs separately for every image placement, after the
10-character drop, against the cleaned native text of the same page. Two images
on the same page can both contribute the same OCR text; only text already
present in the native layer is removed. The check is not used for DOCX or
PPTX.

### Vector images

- **EMF+** records are parsed in Swift: the embedded BGRA/BGR bitmap is
  extracted, alpha-flattened onto white and written as PNG with CoreGraphics.
- **EMF** is converted to SVG with `emf2svg-conv`, then to PNG with
  `rsvg-convert`.
- **SVG** is rendered with `rsvg-convert`.
- **WMF** has no renderer; DOCX reports it as a vector image that was not OCR'd.
- For DOCX, if none of these produce an image, the file is listed under
  `## Vector images (not OCR'd)` rather than silently dropped. PPTX has no
  vector-failure list; its unrenderable vector pictures are dropped like empty
  OCR text.

### Markdown and token counts

The body title is the file stem with only the final extension removed and
whitespace runs collapsed. Markdown is assembled in Swift: front matter, title,
body, figures, comments and page/slide markers. DOCX output order is header
blockquote, Pandoc body, figures section, unanchored-comments appendix, then
vector list. PPTX notes and comments follow their slide; PDF OCR blocks stay
inside their page. Output files are UTF-8, trimmed of outer whitespace, and end
with one newline.

`cp4ai` and the Finder Services wrap each document in
`[name BEGIN]`/`[name END]` markers; `md4ai` files contain no wrappers.
Clipboard documents are separated by one blank line and the whole clipboard
text ends with one newline. `characters` counts the Unicode scalars in that
complete text, including wrappers and the final newline. `tokens` are exact
`cl100k_base` tokens of the same text.

### Job queue and parallelism

Conversion is a queue of three kinds of jobs:

1. **Text extraction** — Pandoc for DOCX/PPTX.
2. **PDF extraction** — the PyMuPDF helper produces page Markdown and
   per-image placement PNGs.
3. **OCR** — Apple Vision processes one image placement or full PDF page.

Each document starts with an extraction job. When it finishes, it enqueues its
OCR jobs; extraction for other documents continues while those OCR jobs run.
There is no stage barrier between documents. The queue has N workers, and each
worker executes one job at a time on one thread; jobs never spawn nested worker
pools.

`--jobs N` sets N. The CLI defaults to all active CPU cores; the Finder
Services cap themselves at `min(cpu cores, 6)` so Vision does not exhaust
memory.

The OCR text is not inserted while the queue is running. Once the queue is
completely drained, Swift assembles every document in input order, replaces
images with the cached OCR text and writes the outputs. This keeps document
ordering deterministic and avoids partial Markdown files.

If extraction for one document fails, that document is recorded as failed and
other documents continue. Assembly still writes every successful `md4ai`
output; the batch then reports the failures and exits non-zero. `cp4ai` and the
Finder Services leave the clipboard unchanged when any document failed.
