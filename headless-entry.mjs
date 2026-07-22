#!/usr/bin/env node
/**
 * Open Design Headless Entry Point
 * ==================================
 * Wraps the standard OD daemon startup and injects a headless Playwright
 * slide renderer, enabling PDF/PPTX/Image exports on self-hosted (non-Electron)
 * deployments.
 *
 * CRITICAL: Uses async execFile (not execFileSync) to avoid blocking the
 * Node.js event loop. The renderer loads assets from localhost:7457 — if
 * the event loop is blocked, the daemon can't serve those requests.
 *
 * This replaces: node apps/daemon/bin/od.mjs --host 0.0.0.0 --port 7457 --no-open
 * With:          node headless-entry.mjs --host 0.0.0.0 --port 7457
 */

import { execFile } from 'node:child_process';
import { mkdirSync, writeFileSync, unlinkSync, readFileSync, existsSync } from 'node:fs';
import { join, extname } from 'node:path';
import { randomBytes } from 'node:crypto';
import { promisify } from 'node:util';

const execFileAsync = promisify(execFile);

// Parse CLI args (matching the daemon's interface)
const args = process.argv.slice(2);
const hostIdx = args.indexOf('--host');
const portIdx = args.indexOf('--port');
const host = hostIdx >= 0 ? args[hostIdx + 1] : process.env.OD_BIND_HOST || '0.0.0.0';
const port = portIdx >= 0 ? parseInt(args[portIdx + 1], 10) : parseInt(process.env.OD_PORT || '7457', 10);

console.info('[headless-entry] Starting OD daemon with headless slide renderer');
console.info(`[headless-entry] host=${host} port=${port}`);

// Resolve Python interpreter (prefer venv)
const PYTHON = process.env.PYTHON_PATH || '/opt/venv/bin/python3';
const RENDERER_SCRIPT = join(import.meta.dirname || process.cwd(), 'headless-renderer.py');
const RENDER_TIMEOUT_MS = 120_000;

const rendererEnv = {
    ...process.env,
    PLAYWRIGHT_BROWSERS_PATH: process.env.PLAYWRIGHT_BROWSERS_PATH || '/opt/pw-browsers',
};

/**
 * Headless slide renderer — replaces the Electron desktop renderer.
 * Uses async execFile to keep the event loop free for serving assets.
 *
 * Input:  { baseHref, html, deck, outputDir, pageImageFormat, index, stitch, paginate, width, height, editable }
 * Output: { ok, slideFiles, width, height, mode, error }
 */
async function headlessSlideRenderer(input) {
    const inputId = randomBytes(8).toString('hex');
    const inputDir = join(process.env.RUNTIME_DATA_DIR || '/tmp', 'headless-render-input');
    mkdirSync(inputDir, { recursive: true });
    const inputPath = join(inputDir, `${inputId}.json`);

    try {
        writeFileSync(inputPath, JSON.stringify(input));

        const { stdout, stderr } = await execFileAsync(PYTHON, [RENDERER_SCRIPT, inputPath], {
            timeout: RENDER_TIMEOUT_MS,
            maxBuffer: 50 * 1024 * 1024,
            env: rendererEnv,
        });

        if (stderr) {
            console.warn('[headless-entry] Renderer stderr:', stderr.slice(0, 500));
        }

        const result = JSON.parse(stdout.toString().trim());
        return result;
    } catch (err) {
        console.error('[headless-entry] Renderer error:', err.message);
        if (err.stderr) console.error('[headless-entry] Renderer stderr:', err.stderr.toString().slice(0, 1000));
        return { ok: false, error: `headless renderer failed: ${err.message}` };
    } finally {
        try { unlinkSync(inputPath); } catch {}
    }
}

/**
 * Headless PDF exporter — uses Playwright's page.pdf() for vector PDF.
 * This is the CJK-problematic path; prefer the screenshot PDF (pdf-image)
 * for full fidelity. But we provide it so the route doesn't 501.
 */
async function headlessPdfExporter(input) {
    const inputId = randomBytes(8).toString('hex');
    const inputDir = join(process.env.RUNTIME_DATA_DIR || '/tmp', 'headless-render-input');
    mkdirSync(inputDir, { recursive: true });
    const inputPath = join(inputDir, `pdf-${inputId}.json`);

    try {
        writeFileSync(inputPath, JSON.stringify(input));

        // Write a Python script that renders to PDF
        const pdfScriptPath = join(inputDir, `pdf-script-${inputId}.py`);
        writeFileSync(pdfScriptPath, `
import json, sys, os, base64, re
from playwright.sync_api import sync_playwright

with open(sys.argv[1], "r") as f:
    input_data = json.load(f)

html = input_data.get('html', '')
base_href = input_data.get('baseHref', '')
default_filename = input_data.get('defaultFilename', 'export.pdf')

if base_href:
    if '<head' in html.lower():
        html = re.sub(r'(<head[^>]*>)', rf'\\1<base href="{base_href}">', html, count=1, flags=re.IGNORECASE)
    else:
        html = f'<base href="{base_href}">' + html

with sync_playwright() as p:
    browser = p.chromium.launch(headless=True, args=['--no-sandbox', '--disable-gpu', '--disable-web-security'])
    page = browser.new_page(viewport={'width': 1920, 'height': 1080})
    page.set_content(html, wait_until='networkidle', timeout=60000)
    page.wait_for_timeout(500)
    pdf_bytes = page.pdf(
        format='A4',
        landscape=True,
        print_background=True,
        margin={'top': '0', 'right': '0', 'bottom': '0', 'left': '0'},
    )
    browser.close()
    result = {
        'ok': True,
        'defaultFilename': default_filename,
        'contentType': 'application/pdf',
        'data': base64.b64encode(pdf_bytes).decode(),
    }
    print(json.dumps(result))
`);

        const { stdout } = await execFileAsync(PYTHON, [pdfScriptPath, inputPath], {
            timeout: RENDER_TIMEOUT_MS,
            maxBuffer: 100 * 1024 * 1024,
            env: rendererEnv,
        });

        const result = JSON.parse(stdout.toString().trim());
        if (result.ok && result.data) {
            result.pdf = Buffer.from(result.data, 'base64');
            delete result.data;
        }
        return result;
    } catch (err) {
        console.error('[headless-entry] PDF exporter error:', err.message);
        return { ok: false, error: `headless PDF export failed: ${err.message}` };
    } finally {
        try { unlinkSync(inputPath); } catch {}
        try { unlinkSync(join(inputDir, `pdf-script-${inputId}.py`)); } catch {}
    }
}

// ---------------------------------------------------------------------------
// PDF fetch monkey-patch (injected into frontend HTML pages)
// ---------------------------------------------------------------------------
const HEADLESS_PATCH = `<script data-od-headless-patch>
(function(){
  // --- PDF fetch monkey-patch ---
  // Redirect /export/pdf → /export/pdf-image for blob download
  var origFetch = window.fetch;
  window.fetch = function(url, opts) {
    if (typeof url === 'string'
        && /\\/export\\/pdf$/.test(url)
        && opts && opts.method === 'POST') {
      var pdfUrl = url.replace(/\\/export\\/pdf$/, '/export/pdf-image');
      return origFetch.call(this, pdfUrl, opts).then(function(resp) {
        if (!resp.ok) return resp;
        return resp.blob().then(function(blob) {
          var cd = resp.headers.get('content-disposition') || '';
          var fn = 'slides.pdf';
          var m = cd.match(/filename\\*?=(?:UTF-8'')?([^;]+)/);
          if (m) fn = decodeURIComponent(m[1].replace(/"/g, ''));
          var a = document.createElement('a');
          a.href = URL.createObjectURL(blob);
          a.download = fn;
          document.body.appendChild(a);
          a.click();
          a.remove();
          setTimeout(function(){ URL.revokeObjectURL(a.href); }, 5000);
          return new Response(JSON.stringify({ok:true}),
            {status:200, headers:{'content-type':'application/json'}});
        });
      });
    }
    return origFetch.apply(this, arguments);
  };

  // --- Image export server-side fallback ---
  // The frontend captures canvas snapshots from iframes which can fail
  // (cross-origin taint, mobile limitations, headless mode).
  // This observer detects the image export dialog and hijacks the Save button
  // to use the server's /export/image endpoint instead.
  function setupImageExportPatch() {
    var observer = new MutationObserver(function(mutations) {
      mutations.forEach(function(m) {
        m.addedNodes.forEach(function(node) {
          if (node.nodeType !== 1) return;
          var dialog = node.querySelector ? node.querySelector('[role=dialog]') || (node.getAttribute && node.getAttribute('role') === 'dialog' ? node : null) : null;
          if (!dialog) return;
          var heading = dialog.querySelector('h2');
          if (!heading) return;
          var text = heading.textContent || '';
          if (!/export.*image|匯出.*圖片/i.test(text)) return;
          // Found the image export dialog — attach handler to Save button
          var saveBtn = dialog.querySelector('button:last-child');
          if (!saveBtn || /cancel|取消/i.test(saveBtn.textContent)) return;
          var origClick = null;
          saveBtn.addEventListener('click', function handler(e) {
            e.preventDefault();
            e.stopPropagation();
            e.stopImmediatePropagation();
            // Determine format from checked radio
            var radios = dialog.querySelectorAll('input[type=radio]');
            var fmt = 'png';
            radios.forEach(function(r) {
              if (r.checked) {
                var label = (r.getAttribute('aria-label') || r.value || '').toLowerCase();
                if (/jpeg|jpg/.test(label)) fmt = 'jpeg';
                else if (/webp/.test(label)) fmt = 'webp';
                else fmt = 'png';
              }
            });
            // Extract projectId and fileName from URL
            var urlMatch = location.pathname.match(/\\/projects\\/([^/]+)/);
            var projectId = urlMatch ? urlMatch[1] : null;
            // Find fileName from context — look for file path indicator in the page
            var fileEl = document.querySelector('[class*="context"] [title*=".html"], [data-testid*="file"]');
            var fileName = 'index.html';
            // Try to get from tab bar or file indicators
            var tabs = document.querySelectorAll('[role=tab][aria-selected=true]');
            tabs.forEach(function(t) {
              var txt = (t.textContent || '').trim().replace(/\\s*Close.*$/i, '').trim();
              if (/\\.html$/.test(txt)) fileName = txt;
            });
            if (!projectId) {
              alert('Cannot determine project ID');
              return;
            }
            // Detect current slide index from the speaker notes panel or navigation
            // OD shows "Slide 2 / 5" in span.speaker-notes-panel-meta
            // or "2/5" in div.comment-preview-canvas
            var slideIndex = 0;
            var slideDetected = false;
            var metaEl = document.querySelector('.speaker-notes-panel-meta');
            if (metaEl) {
              var nm = (metaEl.textContent || '').match(/(\\d+)\\s*\\/\\s*(\\d+)/);
              if (nm) { slideIndex = parseInt(nm[1], 10) - 1; slideDetected = true; }
            }
            if (!slideDetected) {
              // Fallback: search for "N/M" pattern in deck-specific elements only
              var navEl = document.querySelector('.comment-preview-canvas, .deck-nav, .slide-counter');
              if (navEl) {
                var nm = (navEl.textContent || '').match(/(\\d+)\\s*\\/\\s*(\\d+)/);
                if (nm && parseInt(nm[2],10) > 1) { slideIndex = parseInt(nm[1],10) - 1; slideDetected = true; }
              }
            }
            // Detect if this is a deck
            var isDeck = slideDetected || !!document.querySelector('.deck-thumbnail-rail, .deck-thumbnail-list');
            // Call server export (server only supports png/jpeg; webp done client-side)
            var serverFmt = (fmt === 'webp') ? 'png' : fmt;
            var ext = fmt === 'jpeg' ? 'jpg' : fmt;
            var reqBody = {fileName: fileName, index: slideIndex, imageFormat: serverFmt};
            if (isDeck) reqBody.deck = true;
            var body = JSON.stringify(reqBody);
            fetch('/api/projects/' + encodeURIComponent(projectId) + '/export/image', {
              method: 'POST',
              headers: {'content-type': 'application/json'},
              body: body
            }).then(function(resp) {
              if (!resp.ok) throw new Error('Export failed: ' + resp.status);
              return resp.blob();
            }).then(function(blob) {
              // If webp requested, re-encode via canvas
              if (fmt === 'webp') {
                return new Promise(function(resolve, reject) {
                  var img = new Image();
                  img.onload = function() {
                    var c = document.createElement('canvas');
                    c.width = img.naturalWidth; c.height = img.naturalHeight;
                    var ctx = c.getContext('2d');
                    ctx.drawImage(img, 0, 0);
                    c.toBlob(function(b) {
                      URL.revokeObjectURL(img.src);
                      b ? resolve(b) : reject(new Error('WebP encoding failed'));
                    }, 'image/webp', 0.92);
                  };
                  img.onerror = function() { reject(new Error('Failed to load image for WebP conversion')); };
                  img.src = URL.createObjectURL(blob);
                });
              }
              return blob;
            }).then(function(blob) {
              var baseName = fileName.replace(/\\.html$/, '');
              var fn = slideIndex > 0 ? baseName + '-slide' + (slideIndex + 1) + '.' + ext : baseName + '.' + ext;
              var a = document.createElement('a');
              a.href = URL.createObjectURL(blob);
              a.download = fn;
              document.body.appendChild(a);
              a.click();
              a.remove();
              setTimeout(function(){ URL.revokeObjectURL(a.href); }, 5000);
              // Close dialog
              var cancelBtn = dialog.querySelector('button');
              if (cancelBtn && /cancel|取消/i.test(cancelBtn.textContent)) cancelBtn.click();
            }).catch(function(err) {
              console.error('[od-headless-patch] Image export failed:', err);
              alert('Image export failed: ' + err.message);
            });
            saveBtn.removeEventListener('click', handler);
          }, {capture: true, once: true});
        });
      });
    });
    observer.observe(document.body || document.documentElement, {childList: true, subtree: true});
  }
  if (document.body) setupImageExportPatch();
  else document.addEventListener('DOMContentLoaded', setupImageExportPatch);
})();
</script>`;

// ---------------------------------------------------------------------------
// Standalone HTML image inliner
// ---------------------------------------------------------------------------
const MIME_MAP = {
    '.png': 'image/png', '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg',
    '.gif': 'image/gif', '.svg': 'image/svg+xml', '.webp': 'image/webp',
    '.ico': 'image/x-icon', '.bmp': 'image/bmp', '.avif': 'image/avif',
};

function inlineImages(html, projectId) {
    const projectDir = join('/app/.od/projects', projectId);
    let count = 0;

    // 1. <img src="assets/..."> and similar src= on media elements
    html = html.replace(
        /(<(?:img|video|source|audio)\b[^>]*?\bsrc\s*=\s*)(["'])(assets\/[^"'\s>]+)\2/gi,
        (match, prefix, quote, assetPath) => {
            const fullPath = join(projectDir, assetPath);
            if (!existsSync(fullPath)) return match;
            try {
                const data = readFileSync(fullPath);
                const mime = MIME_MAP[extname(assetPath).toLowerCase()] || 'application/octet-stream';
                count++;
                return `${prefix}${quote}data:${mime};base64,${data.toString('base64')}${quote}`;
            } catch { return match; }
        }
    );

    // 2. CSS url(assets/...) in <style> blocks and inline styles
    html = html.replace(
        /url\(\s*(["']?)(assets\/[^"')]+)\1\s*\)/gi,
        (match, quote, assetPath) => {
            const fullPath = join(projectDir, assetPath);
            if (!existsSync(fullPath)) return match;
            try {
                const data = readFileSync(fullPath);
                const mime = MIME_MAP[extname(assetPath).toLowerCase()] || 'application/octet-stream';
                count++;
                return `url("data:${mime};base64,${data.toString('base64')}")`;
            } catch { return match; }
        }
    );

    console.info(`[headless-entry] inlineImages: ${count} assets embedded for project ${projectId}`);
    return html;
}

// Import and start the server with renderers injected
try {
    const { startServer } = await import('./apps/daemon/dist/server.js');

    console.info('[headless-entry] Injecting headless renderers into startServer()');

    const result = await startServer({
        host,
        port,
        desktopSlideRenderer: headlessSlideRenderer,
        desktopPdfExporter: headlessPdfExporter,
        desktopArtifactExporter: null,  // Falls back to desktopSlideRenderer path
        returnServer: true,
    });

    const httpServer = result.server;
    console.info(`[headless-entry] Server started at ${result.url}`);
    console.info('[headless-entry] Headless slide renderer: ACTIVE');
    console.info('[headless-entry] Headless PDF exporter: ACTIVE');
    console.info('[headless-entry] Export routes: PDF, PPTX, Image, PDF-Image now enabled');

    // -----------------------------------------------------------------------
    // Response interceptor layer
    // Wraps the Express app to fix two response format issues:
    //   1. PDF export: convert JSON Buffer → binary file download
    //   2. HTML export: inline <img src="assets/..."> as base64 data URIs
    // -----------------------------------------------------------------------
    const listeners = httpServer.listeners('request');
    const expressApp = listeners[0];
    httpServer.removeAllListeners('request');

    httpServer.on('request', (req, res) => {
        const url = req.url || '';

        // --- PDF: inject fetch monkey-patch into frontend HTML pages ---
        // The frontend's dc() for /export/pdf is designed for Electron IPC:
        //   1. Calls fetch() → t.json().catch(()=>({})) → returns "desktop"
        //   2. No code path exists to trigger a file download
        //
        // Fix: Inject a <script> into HTML pages that monkey-patches fetch().
        // When the frontend calls POST /export/pdf, the patch redirects it to
        // /export/pdf-image (screenshot PDF, binary + Content-Disposition),
        // triggers a blob download, then returns {ok:true} to satisfy dc().

        // --- HTML response interceptor ---
        // Two purposes:
        //   1. Inline export: embed <img src="assets/..."> as base64 data URIs
        //   2. App pages: inject PDF fetch monkey-patch into <head>
        const isInlineExport = req.method === 'GET' && /\/api\/projects\/[^/]+\/export\//.test(url) && /[?&]inline=/.test(url);
        const isAppPage = req.method === 'GET' && !url.startsWith('/api/') && !url.startsWith('/_next/') && !/\.(js|css|png|jpg|svg|ico|woff|json|map|txt)(\?|$)/.test(url);

        if (isInlineExport || isAppPage) {
            const projectMatch = isInlineExport ? url.match(/\/api\/projects\/([^/]+)\/export\//) : null;
            const projectId = projectMatch?.[1];

            const origEnd = res.end;
            const origWrite = res.write;
            const chunks = [];

            res.write = function (chunk, encoding, callback) {
                if (chunk) chunks.push(typeof chunk === 'string' ? Buffer.from(chunk, encoding || 'utf8') : chunk);
                if (typeof encoding === 'function') encoding();
                else if (typeof callback === 'function') callback();
                return true;
            };

            res.end = function (chunk, encoding, callback) {
                if (chunk) chunks.push(typeof chunk === 'string' ? Buffer.from(chunk, encoding || 'utf8') : chunk);
                const body = Buffer.concat(chunks);
                const ct = res.getHeader('content-type') || '';
                if (typeof ct === 'string' && ct.includes('text/html')) {
                    let html = body.toString('utf8');
                    // Inline export: embed images
                    if (isInlineExport && projectId) {
                        try { html = inlineImages(html, projectId); } catch (e) {
                            console.error('[headless-entry] inlineImages error:', e.message);
                        }
                    }
                    // App page: inject PDF fetch patch
                    if (isAppPage && html.includes('</head>') && !html.includes('data-od-headless-patch')) {
                        html = html.replace('</head>', HEADLESS_PATCH + '</head>');
                    }
                    const buf = Buffer.from(html, 'utf8');
                    res.setHeader('Content-Length', buf.length);
                    return origEnd.call(res, buf, 'utf8', typeof encoding === 'function' ? encoding : callback);
                }
                return origEnd.call(res, body, undefined, typeof encoding === 'function' ? encoding : callback);
            };
        }

        expressApp(req, res);
    });

    console.info('[headless-entry] Response interceptors: PDF binary + HTML image inlining ACTIVE');

    // Keep process alive
    process.on('SIGTERM', () => {
        console.info('[headless-entry] SIGTERM received, shutting down...');
        Promise.resolve(result.shutdown?.()).catch(() => {}).finally(() => process.exit(0));
    });
    process.on('SIGINT', () => {
        console.info('[headless-entry] SIGINT received, shutting down...');
        Promise.resolve(result.shutdown?.()).catch(() => {}).finally(() => process.exit(0));
    });
} catch (err) {
    console.error('[headless-entry] Failed to start server:', err);
    process.exit(1);
}
