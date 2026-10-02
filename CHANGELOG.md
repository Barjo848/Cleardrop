# Changelog

## 0.0.0

First public version.

- Removes document Info, XMP metadata, private application data, annotation authors and
  dates, and JPEG Exif/XMP/IPTC; replaces the file ID. Writes only objects the document
  still references.
- Reads PDF 1.0–1.7 and 2.0 with classic cross-reference tables, cross-reference streams,
  object streams and hybrid layouts, including incremental saves. Writes a classic table.
- Refuses encrypted files, files with a completed signature, and damaged files.
- The review lists what will be removed and what stays; the done message reports what the
  saved file shows.
- Optional compression in five steps. The lossy steps re-encode only RGB and gray JPEG
  images, at a stated quality and pixel limit.
- Opens files by drop, File → Open, Open With, or the Dock icon. Sandboxed, hardened
  runtime, Apple Silicon, macOS 14 or later. Built from source; not notarized.
- Can be packaged as a standard installer, and removes itself through
  Cleardrop → Uninstall Cleardrop…
