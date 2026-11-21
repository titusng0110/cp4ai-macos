#!/usr/bin/env python3
"""PDF text extraction and OCR-image rasterisation for Copy 4 AI.

This helper is the only Python code in the app.  It does not OCR.  It returns
the PyMuPDF Markdown for every page plus one PNG per image placement that may
contain text.  The Swift app runs Vision OCR and assembles the final document.

Images are discovered from the PDF image objects, not from the layout model.
For PDFs with optional content groups (layers), visibility is toggled so images
on hidden layers are discovered too.  A lower image is skipped when a later,
fully opaque image completely covers its bounding box.

Commands
--------
probe   --input X.pdf              page and image counts, for progress
extract --input X.pdf --output DIR page Markdown + image PNGs + document.json

The JSON schema is versioned with ``schema``.  stdout carries JSON only; all
diagnostics go to stderr.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path

import pymupdf

pymupdf.use_layout(True)

SCHEMA = 2
DPI = 300
TOKEN_RE = re.compile(r"[a-z0-9]{2,}")


def token_set(text: str) -> set[str]:
    return set(TOKEN_RE.findall(text.lower()))


def bbox_contains(outer: pymupdf.Rect, inner: pymupdf.Rect, tolerance: float = 0.5) -> bool:
    return (
        outer.x0 <= inner.x0 + tolerance
        and outer.y0 <= inner.y0 + tolerance
        and outer.x1 >= inner.x1 - tolerance
        and outer.y1 >= inner.y1 - tolerance
    )


def image_is_fully_opaque(doc: pymupdf.Document, info: dict, cache: dict[int, bool]) -> bool:
    """Return True only when the image has no transparency.

    PDF images are normally made transparent with an /SMask.  A soft mask that
    is entirely 255 is still opaque.  Unknown masks and color-key masks are
    treated conservatively as transparent, so the lower image is not skipped.
    """
    xref = int(info.get("xref") or 0)
    if xref <= 0:
        return False
    if xref in cache:
        return cache[xref]

    if not info.get("has-mask"):
        cache[xref] = True
        return True

    try:
        extracted = doc.extract_image(xref)
        smask = int(extracted.get("smask") or 0)
        if smask <= 0:
            cache[xref] = False
            return False
        mask = pymupdf.Pixmap(doc, smask)
        opaque = bool(mask.samples) and all(value == 255 for value in mask.samples)
        cache[xref] = opaque
        return opaque
    except Exception:
        cache[xref] = False
        return False


def layer_ui_items(doc: pymupdf.Document) -> list[dict]:
    try:
        return [
            item
            for item in doc.layer_ui_configs()
            if item.get("type") in {"checkbox", "radiobox"}
        ]
    except Exception:
        return []


def restore_layer_state(doc: pymupdf.Document, items: list[dict], original: dict[int, bool]) -> None:
    for item in items:
        number = item["number"]
        action = 0 if original.get(number) else 2
        try:
            doc.set_layer_ui_config(number, action=action)
        except Exception:
            pass


def collect_placements(doc: pymupdf.Document, page: pymupdf.Page) -> list[dict]:
    """Collect visible image placements across the default and isolated layers."""
    items = layer_ui_items(doc)
    original: dict[int, bool] = {item["number"]: bool(item.get("on")) for item in items}
    states: list[int | None] = [None]
    states.extend(item["number"] for item in items)

    placements: list[dict] = []
    seen: set[tuple] = set()
    opacity_cache: dict[int, bool] = {}

    def collect_state() -> None:
        infos = page.get_image_info(xrefs=True)
        clipped: list[tuple[dict, pymupdf.Rect]] = []
        for info in infos:
            box = pymupdf.Rect(info["bbox"]) & page.rect
            if box.is_empty or box.width <= 1 or box.height <= 1:
                continue
            clipped.append((info, box))

        opaque = [
            image_is_fully_opaque(doc, info, opacity_cache)
            for info, _box in clipped
        ]

        survivors: list[tuple[dict, pymupdf.Rect, bool]] = []
        for index, (info, box) in enumerate(clipped):
            covered = any(
                bbox_contains(other_box, box) and opaque[other_index]
                for other_index, (other, other_box) in enumerate(clipped)
                if other_index > index
            )
            if not covered:
                survivors.append((info, box, opaque[index]))

        for info, box, is_opaque in survivors:
            xref = int(info.get("xref") or 0)
            key = (
                xref,
                tuple(round(value, 1) for value in box),
                bytes(info.get("digest") or b""),
            )
            if key in seen:
                continue
            seen.add(key)
            overlaps = any(
                other_box.intersects(box)
                for other, other_box, _ in survivors
                if other is not info
            )
            placements.append(
                {
                    "bbox": [float(box.x0), float(box.y0), float(box.x1), float(box.y1)],
                    "xref": xref,
                    "digest": bytes(info.get("digest") or b"").hex(),
                    "opaque": is_opaque,
                    "overlap": overlaps,
                    "info": info,
                }
            )

    try:
        for target in states:
            try:
                if target is None:
                    restore_layer_state(doc, items, original)
                else:
                    for item in items:
                        doc.set_layer_ui_config(item["number"], action=2)
                    doc.set_layer_ui_config(target, action=0)
                collect_state()
            except Exception:
                if target is None:
                    raise
                # A malformed layer entry should not lose the default pass.
                continue
    finally:
        restore_layer_state(doc, items, original)

    return placements


def render_image_placement(
    doc: pymupdf.Document,
    page: pymupdf.Page,
    placement: dict,
    output: Path,
    index: int,
) -> dict:
    box = pymupdf.Rect(placement["bbox"]) & page.rect
    file = output / f"p{page.number + 1:04d}_i{index:04d}.png"
    xref = placement["xref"]
    info = placement["info"]

    # When images overlap on the same layer, a page crop would contain pieces
    # of both.  Extracting the image object gives clean pixels for OCR.
    if placement["overlap"] and xref > 0:
        try:
            pix = pymupdf.Pixmap(doc, xref)
            pix.save(file)
        except Exception:
            pix = page.get_pixmap(clip=box, dpi=DPI, alpha=False)
            pix.save(file)
    else:
        pix = page.get_pixmap(clip=box, dpi=DPI, alpha=False)
        pix.save(file)

    return {
        "file": file.name,
        "bbox": placement["bbox"],
        "sha256": hashlib.sha256(file.read_bytes()).hexdigest(),
        "kind": "image",
        "width": int(round(box.width)),
        "height": int(round(box.height)),
    }


def render_full_page(page: pymupdf.Page, output: Path) -> dict:
    file = output / f"p{page.number + 1:04d}_page.png"
    pix = page.get_pixmap(dpi=DPI, alpha=False)
    pix.save(file)
    return {
        "file": file.name,
        "bbox": [0.0, 0.0, float(page.rect.width), float(page.rect.height)],
        "sha256": hashlib.sha256(file.read_bytes()).hexdigest(),
        "kind": "page",
        "width": int(round(page.rect.width)),
        "height": int(round(page.rect.height)),
    }


def page_has_text(page: pymupdf.Page) -> bool:
    return len(token_set(page.get_text())) >= 40


def probe(path: Path) -> dict:
    with pymupdf.open(path) as doc:
        pages = []
        jobs = 0
        for page in doc:
            infos = page.get_image_info(xrefs=True)
            count = sum(
                1
                for info in infos
                if not (pymupdf.Rect(info["bbox"]) & page.rect).is_empty
            )
            if count == 0 and not page_has_text(page):
                count = 1
            jobs += count
            pages.append({"number": page.number + 1, "images": count})
        return {
            "schema": SCHEMA,
            "pymupdf": pymupdf.__version__,
            "page_count": doc.page_count,
            "ocr_jobs": jobs,
            "pages": pages,
        }


def extract(path: Path, output: Path) -> dict:
    output.mkdir(parents=True, exist_ok=True)
    with pymupdf.open(path) as doc:
        chunks = doc.to_markdown(page_chunks=True, show_progress=False, use_ocr=False)
        pages = []
        for index, chunk in enumerate(chunks):
            page = doc[index] if index < doc.page_count else None
            entry = {
                "number": index + 1,
                "markdown": chunk.get("text", ""),
                "width": float(page.rect.width) if page is not None else 0.0,
                "height": float(page.rect.height) if page is not None else 0.0,
                "images": [],
            }
            if page is not None:
                placements = collect_placements(doc, page)
                for image_index, placement in enumerate(placements):
                    entry["images"].append(
                        render_image_placement(
                            doc, page, placement, output, image_index
                        )
                    )
                if not placements and not page_has_text(page):
                    entry["images"].append(render_full_page(page, output))
            pages.append(entry)
        return {
            "schema": SCHEMA,
            "pymupdf": pymupdf.__version__,
            "page_count": doc.page_count,
            "pages": pages,
        }


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="cp4ai-pdf")
    parser.add_argument("--version", action="version", version=f"%(prog)s {SCHEMA}")
    sub = parser.add_subparsers(dest="command", required=True)

    probe_parser = sub.add_parser("probe")
    probe_parser.add_argument("--input", type=Path, required=True)

    extract_parser = sub.add_parser("extract")
    extract_parser.add_argument("--input", type=Path, required=True)
    extract_parser.add_argument("--output", type=Path, required=True)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        if not args.input.is_file():
            raise FileNotFoundError(f"not found: {args.input}")
        if args.command == "probe":
            result = probe(args.input)
        else:
            result = extract(args.input, args.output)
    except Exception as exc:  # noqa: BLE001 - reported to the Swift caller
        print(f"cp4ai-pdf: {exc}", file=sys.stderr)
        return 2
    json.dump(result, sys.stdout, ensure_ascii=False, separators=(",", ":"))
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
