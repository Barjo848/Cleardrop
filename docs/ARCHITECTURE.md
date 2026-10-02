# Architecture

Cleardrop is two layers. `Sources/Cleardrop/Engine/` is a pure function from PDF bytes to PDF
bytes with no UI framework and no PDFKit. `Sources/Cleardrop/App/` is a thin SwiftUI window
that calls it. The tests compile the engine alone.

## Pipeline

```
bytes → PDFParser → PDFDocumentGraph → PDFStripper → PDFReachability → PDFCompressor → PDFWriter → bytes
```

- **`PDFParser`** reads the header and the last `startxref`, then walks the cross-reference
  sections from the newest back through `/Prev`. A section is either a classic `xref` table or
  a cross-reference stream (`PDFXRefStream`); a table may also name a companion stream with
  `/XRefStm` (a hybrid file). The newest entry for each object number wins, so an
  incrementally saved file is read as its current state. It then loads every object,
  unpacking the ones stored in object streams (`PDFObjectStream`). The parser does not repair
  anything: input it cannot read exactly is refused.
- Only cross-reference streams and object streams are ever decompressed (`Inflate.swift`),
  and only Flate with no predictor or a PNG predictor. All inflation for one file shares a
  256 MB budget. Page content, fonts and images are kept as the raw bytes found in the file.
- The object-stream and cross-reference-stream containers are file structure, so they are not
  part of the graph. Their contents are, as ordinary objects.
- **`PDFDocumentGraph`** (`PDFModel.swift`) is the object map, keyed by object number, plus the
  newest trailer dictionary. Object numbers are never renumbered. Names are kept as their raw
  bytes, and reals are written back as plain decimals that read as the same number.
- **`PDFStripper`** detaches metadata from the graph (see below). It removes keys; it does not
  delete the objects they pointed at, because an object can be shared with live content.
- **`PDFReachability`** then keeps only the objects still reachable from the trailer. This is
  the step that removes detached metadata, superseded revisions of an incrementally saved
  file, and objects nothing ever referenced.
- **`PDFCompressor`** and **`ImageRecompressor`** apply the chosen compression level. Level 0
  does nothing.
- **`PDFWriter`** serializes the graph as a new file with one classic `xref` table, whatever
  structure the input used, and keeps the input's PDF version. It never appends to the input
  and never writes `/Prev` or `/Encrypt`. It does not write object streams, so a file that
  used them comes out somewhat larger even though it holds less.
- **`PDFSanitizer`** is the entry point: `inspect` for the review screen, `sanitize` for bytes,
  `process(from:to:)` for files. It refuses a destination that is the source file. Before
  returning, `sanitize` parses its own output and checks that the page count is unchanged.

PDFKit is used only by the tests, as an independent reader that checks the output opens and
renders the same pages.

## The app

One window, one file at a time. A file reaches it by drop, File → Open, Finder's Open With, or
the Dock icon; all four go through `OpenRouting` (`ReviewPhase.swift`), which ignores a new
file only while one is being read or written. The window reads the file, shows the review,
and writes only where the save panel says.

The app is sandboxed with a single file entitlement, access to files the user selects, and
has no network entitlement. `scripts/sign.sh` signs with the hardened runtime and verifies
the result; a signing failure fails the build.

## Installing and uninstalling

`scripts/package.sh` wraps the built app in a standard installer package. The package is
marked not relocatable, so it installs where the person chooses rather than over another
copy found on the disk, and its one script hands the app to the installing user and opens it.

Uninstalling is split between two programs because of the sandbox
(`Sources/Cleardrop/Uninstaller/`):

- The uninstaller is a separate, unsandboxed program inside the bundle
  (`Contents/Helpers/Cleardrop Uninstaller.app`). It acts only when it sits inside a bundle
  named `Cleardrop.app` with Cleardrop's identifier, asks for confirmation, and moves a fixed
  list of items to the Trash (`UninstallPlan`). It searches for nothing and erases nothing.
- macOS does not let another program remove an app's sandbox folder. So, once the person
  confirms, the uninstaller posts a notification and Cleardrop itself erases the contents of
  its own settings folders and exits. Cleardrop listens for that notification only after it
  has opened the uninstaller. The erase is limited to named folders inside the sandbox home
  and never follows a link, because that home also contains links to the person's real
  Desktop, Documents and Downloads.

What remains is the empty sandbox folder, which the uninstaller reports.

## Supported input

PDF 1.0–1.7 and 2.0 files whose cross-reference data is classic tables, cross-reference
streams, or both (hybrid), with or without object streams, saved once or incrementally.

What the tests exercise:

- Hand-written classic fixtures in `Tests/Fixtures/`.
- Generated files (`Tests/StreamFixtures.swift`) laid out the way pdfTeX, Acrobat, size-
  optimising generators and hybrid writers lay theirs out. These are built from the PDF
  specification; they are not output of those programs.
- Real output of pdfTeX and of qpdf (`Tests/InteropTests.swift`), produced during the test
  run. These run when the tool is installed and are required in CI.

To try a folder of your own files without changing or copying them:
`./scripts/corpus_check.sh <directory>`.

## What is refused

Each of these throws a `PDFSanitizerError`; nothing is written.

| Case | Error |
|------|-------|
| Empty input, or no `%PDF-` at byte 0 | `emptyInput`, `notPDF` |
| Larger than 100 MB | `oversize` |
| Trailer has `/Encrypt` | `encrypted` |
| A signature: any `/ByteRange`, a `/Type /Sig` dictionary, a signature field with a `/V` value, a signature filter name, `/DocMDP`, or catalog `/Perms` | `signed` |
| A cross-reference or object stream using a filter other than Flate, or a predictor other than none or PNG | `unsupportedStructure` |
| Cross-reference and object streams that inflate to more than 256 MB in total | `unsupportedStructure` |
| More than 500,000 objects, or more than 4,096 cross-reference sections | `unsupportedStructure` |
| Missing `startxref`, malformed table, object header mismatch | `corrupt` |
| Cross-reference stream with unusable `/W`, `/Index` or `/Size`, or fewer rows than it declares | `corrupt` |
| Object stream whose header, offsets or member index do not match the cross-reference entry | `corrupt` |
| A stream stored inside an object stream, or an object stream stored inside another | `corrupt` |
| Flate data that is damaged or ends early | `corrupt` |
| `/Prev` that points outside the file or forms a cycle | `corrupt` |
| A stream whose `/Length` is missing, not a number, or not followed by `endstream` | `corrupt` |
| Arrays or dictionaries nested more than 256 deep | `corrupt` |
| Unterminated string | `corrupt` |
| A page tree that cannot be followed from the catalog, or that has no pages | `corrupt` |

Some viewers open files in the `corrupt` rows by guessing. Cleardrop does not, because a wrong
guess would change the document without saying so.

## What is removed

The stripper detaches:

- The trailer `/Info` entry.
- `/Metadata` on every object, and every object of `/Type /Metadata`.
- `/PieceInfo` and the `/LastModified` date that accompanies it, on every object.
- The trailer `/ID`, replaced with random bytes.
- On annotations other than widgets: `/T`, `/M`, `/CreationDate`, `/NM`, `/RC`, `/DS`, `/Subj`.
  On widgets: `/M` and `/CreationDate` only, because `/T` is the field name.
- APP1 (Exif, XMP) and APP13 (Photoshop, IPTC) segments inside `DCTDecode` image streams.

The reachability sweep then drops every object that is no longer referenced. That covers the
Info dictionary, anything only it pointed to (including values stored as separate objects),
the XMP and private-data objects, older revisions of replaced objects, and objects that were
never referenced at all. An object that live content still uses is kept even if the Info
dictionary also pointed to it.

Keys are removed from the dictionary of each indirect object. A `/Metadata` or `/PieceInfo`
key inside a dictionary nested directly within another object is not searched for.

## What stays, and how the window knows

Signature detection is deliberately broad: when in doubt, the file is treated as signed and
left alone. The one exception is a signature field (`/FT /Sig`) with no `/V` value, which is
a blank box waiting to be signed. Such a file is cleaned and the field is kept.

The inspection also runs the strip and the sweep on a copy of the graph and looks at what is
left for JavaScript actions, attached files, ICC profiles and output intents, and empty
signature fields. Those are reported as staying in the file. Judging this on the swept copy
matters: something that only removed metadata pointed at is going away and is not listed.

All wording the window shows about a file comes from `ReviewSummary.swift`: the two lists, the
standing note about page content, the button title, and `ExportReport`, which is built by
inspecting the bytes that were written, so the done message cannot claim more than the
saved file shows.

## Compression

| Level | Engine behaviour |
|------:|------------------|
| 0 | Nothing. |
| 1 | Streams with no `/Filter` that are not images are Flate-compressed when that is smaller. |
| 2 | Level 1, and eligible images are re-encoded as JPEG at quality 0.80, long side at most 1600 px. |
| 3 | The same at quality 0.60 and 1200 px. |
| 4 | The same at quality 0.42 and 900 px; images with almost no chroma become grayscale. |

An image is eligible only if all of these hold (`ImageRecompressor.isEligible`):

- it is an image XObject whose only filter is `DCTDecode`, and the data starts as a JPEG;
- `/ColorSpace` is the name `DeviceRGB` or `DeviceGray`, and the JPEG has the matching number
  of components;
- 8 bits per component, no `/SMask`, `/Mask`, `/Decode` or stencil use;
- no other image uses it as a soft mask or mask.

So CMYK, calibrated, ICC-based and indexed colour, Flate, CCITT and JPEG 2000 images, and
anything involved in transparency, are written out byte for byte. A re-encoded image is drawn
in its own colour space, so samples are resampled but not colour-converted, and it replaces
the original only if it is smaller. The pixel cap is on the image's own dimensions; how large
an image is drawn on a page is not measured, which is why no label states a resolution.

The window's level descriptions, the README table and these numbers all come from
`CompressionProfiles.swift`, and a test checks the README against it.

Text and vector content are never rasterized.
