#!/usr/bin/env python3
"""
Open Design Headless Slide Renderer
====================================
Replaces the Electron desktop renderer for self-hosted (bare daemon) deployments.
Uses Playwright Chromium to render slide HTML into screenshots.

Input: JSON file path as CLI argument
Output: JSON result on stdout

Input format:
  {
    "baseHref": "http://localhost:7457/api/projects/{id}/raw/",
    "html": "<html>...</html>",
    "deck": true,
    "outputDir": "/tmp/od-export-render-xxx",
    "pageImageFormat": "png",  // optional: "png" or "jpeg"
    "index": 0,                // optional: specific slide index
    "stitch": false,           // optional: stitch all slides into one image
    "paginate": false,         // optional: paginate long page
    "width": 1920,             // optional
    "height": 1080,            // optional
    "editable": false          // optional: not supported headlessly
  }

Output format:
  {
    "ok": true,
    "slideFiles": ["/path/to/slide-0.png", ...],
    "width": 1920,
    "height": 1080,
    "mode": "deck"
  }
"""

import json
import os
import sys
import time

def main():
    if len(sys.argv) < 2:
        print(json.dumps({"ok": False, "error": "usage: headless-renderer.py <input.json>"}))
        sys.exit(1)

    with open(sys.argv[1], "r") as f:
        input_data = json.load(f)

    html = input_data.get("html", "")
    base_href = input_data.get("baseHref", "")
    output_dir = input_data.get("outputDir", "/tmp/od-render")
    is_deck = input_data.get("deck", False)
    is_editable = input_data.get("editable", False)
    page_image_format = input_data.get("pageImageFormat", "png")
    slide_index = input_data.get("index")
    stitch = input_data.get("stitch", False)
    paginate = input_data.get("paginate", False)
    width = input_data.get("width", 1920)
    height = input_data.get("height", 1080)

    if is_editable:
        print(json.dumps({"ok": False, "error": "editable PPTX export not supported in headless mode"}))
        sys.exit(0)

    os.makedirs(output_dir, exist_ok=True)

    # Inject <base> tag for asset resolution
    if base_href:
        base_tag = f'<base href="{base_href}">'
        if "<head" in html.lower():
            import re
            html = re.sub(r'(<head[^>]*>)', rf'\1{base_tag}', html, count=1, flags=re.IGNORECASE)
        else:
            html = base_tag + html

    try:
        from playwright.sync_api import sync_playwright

        with sync_playwright() as p:
            browser = p.chromium.launch(
                headless=True,
                args=[
                    "--no-sandbox",
                    "--disable-gpu",
                    "--disable-dev-shm-usage",
                    "--disable-web-security",  # allow cross-origin asset loading
                    "--font-render-hinting=none",
                ]
            )

            page = browser.new_page(viewport={"width": int(width), "height": int(height)})

            # Load the HTML content
            page.set_content(html, wait_until="networkidle", timeout=60000)

            # Wait for images and fonts
            page.wait_for_timeout(500)

            # Detect mode
            deck_stage = page.query_selector("deck-stage")
            slide_selector = ".slide, [data-screen-label], .deck-slide, .ppt-slide"
            slides = page.query_selector_all(slide_selector)

            if deck_stage and len(slides) > 0:
                mode = "deck"
                result = render_deck(page, deck_stage, slides, output_dir,
                                     page_image_format, slide_index, stitch,
                                     int(width), int(height))
            elif is_deck and len(slides) > 0:
                mode = "deck"
                result = render_deck_no_stage(page, slides, output_dir,
                                              page_image_format, slide_index, stitch,
                                              int(width), int(height))
            else:
                mode = "page"
                result = render_page(page, output_dir, page_image_format,
                                     paginate, int(width), int(height))

            browser.close()

            print(json.dumps({
                "ok": True,
                "slideFiles": result["files"],
                "width": int(width),
                "height": int(height),
                "mode": mode,
            }))

    except Exception as e:
        print(json.dumps({"ok": False, "error": str(e)}))
        sys.exit(1)


def render_deck(page, deck_stage, slides, output_dir, fmt, index, stitch, w, h):
    """Render deck slides using the <deck-stage> custom element."""
    files = []
    num_slides = len(slides)

    # Set noscale for pixel-perfect rendering
    page.evaluate("document.querySelector('deck-stage')?.setAttribute('noscale', '')")

    if index is not None:
        # Render single slide
        indices = [int(index)]
    else:
        indices = list(range(num_slides))

    for i in indices:
        # Navigate to slide
        page.evaluate(f"""(() => {{
            const stage = document.querySelector('deck-stage');
            if (stage && stage.go) stage.go('go', {i});
        }})()""")
        page.wait_for_timeout(300)

        ext = "jpg" if fmt == "jpeg" else "png"
        filepath = os.path.join(output_dir, f"slide-{i}.{ext}")

        # Screenshot the deck-stage element at design dimensions
        # The stage fills the viewport, so use page screenshot with clip
        page.screenshot(
            path=filepath,
            type="jpeg" if fmt == "jpeg" else "png",
            clip={"x": 0, "y": 0, "width": w, "height": h}
        )
        files.append(filepath)

    if stitch and len(files) > 1:
        files = stitch_images(files, output_dir, fmt)

    return {"files": files}


def render_deck_no_stage(page, slides, output_dir, fmt, index, stitch, w, h):
    """Render deck slides without <deck-stage> (fallback: screenshot each .slide element)."""
    files = []

    if index is not None:
        indices = [int(index)]
    else:
        indices = list(range(len(slides)))

    for i in indices:
        slide = slides[i] if i < len(slides) else None
        if not slide:
            continue

        # Make only this slide visible
        page.evaluate(f"""(() => {{
            const sel = '.slide, [data-screen-label], .deck-slide, .ppt-slide';
            document.querySelectorAll(sel).forEach((s, idx) => {{
                s.style.display = idx === {i} ? '' : 'none';
                s.style.visibility = idx === {i} ? 'visible' : 'hidden';
            }});
        }})()""")
        page.wait_for_timeout(200)

        ext = "jpg" if fmt == "jpeg" else "png"
        filepath = os.path.join(output_dir, f"slide-{i}.{ext}")

        # Try element screenshot first, fallback to viewport
        try:
            box = slide.bounding_box()
            if box and box["width"] > 0 and box["height"] > 0:
                slide.screenshot(path=filepath, type="jpeg" if fmt == "jpeg" else "png")
            else:
                page.screenshot(path=filepath, type="jpeg" if fmt == "jpeg" else "png",
                                clip={"x": 0, "y": 0, "width": w, "height": h})
        except Exception:
            page.screenshot(path=filepath, type="jpeg" if fmt == "jpeg" else "png",
                            clip={"x": 0, "y": 0, "width": w, "height": h})

        files.append(filepath)

    if stitch and len(files) > 1:
        files = stitch_images(files, output_dir, fmt)

    return {"files": files}


def render_page(page, output_dir, fmt, paginate, w, h):
    """Render a full page (non-deck content)."""
    ext = "jpg" if fmt == "jpeg" else "png"
    files = []

    if paginate:
        # Split into viewport-sized chunks by scrolling
        total_height = page.evaluate("document.documentElement.scrollHeight")
        if total_height < 1:
            total_height = h
        page_idx = 0
        y = 0
        while y < total_height:
            # Scroll to position
            page.evaluate(f"window.scrollTo(0, {y})")
            page.wait_for_timeout(150)
            filepath = os.path.join(output_dir, f"page-{page_idx}.{ext}")
            remaining = total_height - y
            clip_h = min(h, remaining)
            if clip_h < 1:
                break
            page.screenshot(
                path=filepath,
                type="jpeg" if fmt == "jpeg" else "png",
                clip={"x": 0, "y": 0, "width": w, "height": clip_h}
            )
            files.append(filepath)
            y += h
            page_idx += 1
    else:
        # Full page screenshot
        filepath = os.path.join(output_dir, f"page-0.{ext}")
        page.screenshot(
            path=filepath,
            type="jpeg" if fmt == "jpeg" else "png",
            full_page=True
        )
        files.append(filepath)

    return {"files": files}


def stitch_images(files, output_dir, fmt):
    """Stitch multiple images into one tall image."""
    try:
        from PIL import Image

        images = [Image.open(f) for f in files]
        total_w = max(img.width for img in images)
        total_h = sum(img.height for img in images)

        stitched = Image.new("RGB", (total_w, total_h), (255, 255, 255))
        y = 0
        for img in images:
            stitched.paste(img, (0, y))
            y += img.height

        ext = "jpg" if fmt == "jpeg" else "png"
        filepath = os.path.join(output_dir, f"stitched.{ext}")
        stitched.save(filepath)
        return [filepath]
    except ImportError:
        # No PIL, return individual files
        return files


if __name__ == "__main__":
    main()
