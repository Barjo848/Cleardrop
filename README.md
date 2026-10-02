# Cleardrop

A small macOS app that removes metadata from a PDF and saves a new copy.

Drop a PDF on the window, review what will be removed and what will stay, optionally
compress, and choose where to save. The original file is never changed. Cleardrop works
offline: it makes no network connections, has no account and collects no telemetry.

---

## Honesty contract (read this first)

### Metadata cleaning

Cleardrop removes **structural identity metadata** from the PDF file format.
It does **not** make a document anonymous if the **page content** still identifies you.

| Cleardrop **does** remove | Cleardrop **does not** remove |
|---------------------------|-------------------------------|
| Document Info (Author, Creator, Producer, dates, keywords, custom keys) | Page text and vector art |
| Catalog and page/object `/Metadata` XMP streams | Photos **as pixels** (unless you choose image compression) |
| Trailer file `/ID` (regenerated) | Embedded attachment **payloads** |
| Application private data (`/PieceInfo`) on the document, pages and forms | JavaScript / OpenAction scripts |
| Annotation authors & modification dates | Font programs & common font names |
| JPEG EXIF / XMP / IPTC in image streams | ICC profiles / layout fingerprinting |
| | Finder facts on the **new** file (size, page count, disk dates) |

Only objects the document still references are written to the new file, so a removed item
is not left behind as an unused object, and neither are earlier versions kept by an
incremental save.

With compression set to **None**, page content is written back byte for byte.

Encrypted and digitally signed PDFs are **refused** (fail closed). A form that only contains
an empty signature field is not signed: it is cleaned, and the field is kept.

The window says the same things. The review lists what will be removed and, separately, what
stays in the file (scripts, attachments, colour profiles, empty signature fields), and always
notes that page text, images and fonts are not changed. After saving, the message is built
from the file that was written: it says how many items were removed, or that none were found.

### Compression (optional)

Compression is a **separate, discrete choice** (None → Maximum). It is **not** redaction.

| Level | What it does |
|------:|--------------|
| **None** | Only removes metadata. Page content and images are left exactly as they are. |
| **Light** | Compresses streams that were stored uncompressed. Most PDFs have none, so this often changes nothing. |
| **Balanced** | Re-encodes JPEG photos at quality 80. Photos longer than 1600 px on their long side are scaled down to 1600 px; smaller ones keep their size. |
| **Strong** | Re-encodes JPEG photos at quality 60. Photos longer than 1200 px on their long side are scaled down to 1200 px. Expect visibly softer photos. |
| **Maximum** | Re-encodes JPEG photos at quality 42 and scales them down to at most 900 px. Photos with almost no colour are converted to grayscale. Photos will look soft or blocky. |

Only RGB and gray JPEG images are re-encoded. CMYK, masked, non-JPEG and other images are left exactly as they are, and text is never turned into an image.

- The pixel limits are about the image's own size. Cleardrop does not measure how large an
  image is drawn on the page, so it makes no resolution claim.
- The output is always a PDF.
- PDFs that are mostly text barely shrink. For each file, the window says how many of its
  images can be re-encoded before you save, and afterwards how many were.
- Size readout: an instant **estimate**, then a **measured dry run** for files up to 15 MB.
- A cleaned copy can be larger than the original when the original stored its objects in
  compressed object streams.

---

## Use

1. Open Cleardrop.
2. Drop a PDF onto the window, choose **File → Open** (⌘O), use **Open With** in Finder, or
   drop the file on the Dock icon.
3. Review **what will be removed**, **what stays**, and the **file size**.
4. Optionally move the **compression** slider; watch the estimated result size.
5. Press the button. It names what will happen, for example **Remove metadata and save…**.
6. Choose the save location (e.g. `Report-clean-balanced.pdf`).
7. **Again** for another file.

Your original is never overwritten. Cleardrop refuses to save over the file you dropped.

### Errors

| Message | Meaning |
|---------|---------|
| `Not a PDF.` | The file is empty or does not start with `%PDF-` |
| `Could not read that PDF.` | The file could not be opened |
| `PDF is password-protected.` | Encrypted |
| `Signed PDFs are not modified.` | A completed signature was detected |
| `PDF is too large.` | Over 100 MB |
| `This PDF is damaged or incomplete.` | The structure is broken; Cleardrop does not guess at repairs |
| `This PDF uses a structure Cleardrop can’t read.` | Valid, but outside what is supported (see Limits) |
| `Could not save the cleaned PDF.` | Writing failed, or the destination is the original file |

---

## Test and build

Requirements: macOS 14 or later on Apple Silicon, with the Xcode command-line tools
(`xcode-select --install`). There are no other dependencies.

Test:

```bash
./scripts/run_tests.sh
```

Build `dist/Cleardrop.app`:

```bash
./scripts/build.sh
```

Optionally copy it to `/Applications`:

```bash
./scripts/install.sh
```

Or build a standard macOS installer, `dist/Cleardrop-<version>.pkg`:

```bash
./scripts/package.sh
```

The installer shows a welcome page, the licence, a choice between installing for all users
or only for you, progress and a summary, and then opens Cleardrop. macOS offers to move the
installer to the Trash when it finishes.

### Uninstalling

Open Cleardrop and choose **Cleardrop → Uninstall Cleardrop…**. After you confirm, the app
erases its own settings and is moved to the Trash; your PDFs are not touched. Empty the Trash
to finish.

Cleardrop is sandboxed and cannot delete itself, so the removal is done by a small separate
program inside the app bundle, which is not sandboxed. macOS also keeps a folder for every
sandboxed app in `~/Library/Containers` and does not let other programs delete it; the
uninstaller empties Cleardrop's settings out of it and tells you where it is. A later install
starts clean either way.

CI runs the same two commands on an Apple Silicon macOS runner. Intel Macs are not built or tested.

To run a subset of the tests: `./scripts/run_tests.sh --only <part of a test name>`.
Two tests use pdfTeX and qpdf if they are installed and are reported as skipped otherwise.

### What you get from a build

The app is sandboxed, with access only to files you choose, and uses the hardened runtime.
`build.sh` signs it ad hoc, which is enough to run it on the Mac that built it; it is not notarized,
so macOS will not open a copy sent to another Mac without a warning. The installer package
is unsigned for the same reason. No prebuilt download is published.

To distribute a build you need your own Apple Developer ID. Nothing in this repository holds
or uses one. With a Developer ID Application certificate in your keychain:

```bash
CLEARDROP_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./scripts/build.sh
```

An installer for other people also needs a Developer ID Installer certificate:

```bash
CLEARDROP_INSTALLER_IDENTITY="Developer ID Installer: Your Name (TEAMID)" ./scripts/package.sh
```

Then submit `dist/Cleardrop.app` or the package to Apple's notary service with `xcrun notarytool` and attach
the ticket with `xcrun stapler`, following Apple's notarization guide. This path is
documented, not exercised by CI.

---

## Limits

- Reads PDF 1.0–1.7 and 2.0 files with classic cross-reference tables, cross-reference
  streams, object streams, or a mix, including incrementally saved files. This is tested in CI
  against real pdfTeX and qpdf output and against generated files in other common layouts.
- Always writes a single classic cross-reference table. A file that used object streams comes
  out somewhat larger, because Cleardrop does not re-pack objects.
- Damaged files are refused rather than repaired, so some files that a viewer opens by
  guessing will not be accepted.
- Password-protected files cannot be opened, even if you know the password.
- Inputs are capped at 100 MB and 500,000 objects.
- One file at a time.
- The writer is Cleardrop's own; PDFKit is not linked into the app, so saving does not stamp a
  new producer string.
- To see how Cleardrop handles a folder of your own PDFs without changing them:
  `./scripts/corpus_check.sh <directory>`.

How the engine works, and every case it refuses: [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).
Reporting a problem: [`SECURITY.md`](SECURITY.md). Changes: [`CHANGELOG.md`](CHANGELOG.md).
Licence: [MIT](LICENSE).
