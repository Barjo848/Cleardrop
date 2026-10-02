# Security

## What Cleardrop does with your files

- Everything happens on your Mac. Cleardrop makes no network connections, has no account and
  collects no telemetry.
- It reads the PDF you give it and writes one new file where you choose. It never modifies the
  original and refuses to save over it.
- The app is sandboxed, with access only to files you choose. The one part that is not
  sandboxed is the uninstaller inside the app bundle. It runs only when you choose
  Uninstall Cleardrop…, asks before acting, and moves Cleardrop and nothing else to the Trash.
- It parses PDFs with its own parser rather than a system library. A parser that reads
  untrusted files can have bugs; treat a crash or a hang on any input as a security issue.

## What it does not protect against

Cleardrop removes structural metadata. It does not make a document anonymous. Text, images,
fonts, attachments, scripts and colour profiles inside the document are left as they are; see
the honesty contract in the README.

## Reporting a problem

Please report privately first, using GitHub's "Report a vulnerability" button on this
repository's Security tab.

Useful reports include:

- a file that makes Cleardrop crash, hang or use unbounded memory;
- a cleaned file that still contains metadata the README says is removed;
- a cleaned file whose pages differ from the original with compression set to None;
- any case where the original file was changed.

If the file is private, describe how it was produced (application and version) instead of
attaching it. Ordinary bugs that expose nothing sensitive can go in a public issue.
