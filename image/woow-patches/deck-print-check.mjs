// deck-print-check.mjs — builds a 3-slide deck from OpenDesign's own deck framework
// (DECK_SKELETON_HTML exported by @open-design/contracts) so a print to PDF can be
// counted: with the ISS-OD-01 fix every slide prints (3 pages), without it only the
// active one does (1 page).
//
//   node deck-print-check.mjs <path to @open-design/contracts dist/index.mjs> <out.html> [--extract]
// --extract reads the DECK_SKELETON_HTML template literal from the file text instead of
// importing the module (for a copy of dist/index.mjs without its node_modules).
import { readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const [, , contracts, out, mode] = process.argv;
let DECK_SKELETON_HTML;
if (mode === "--extract") {
  const src = readFileSync(contracts, "utf8");
  const start = src.indexOf("var DECK_SKELETON_HTML = `");
  const end = src.indexOf("`;\n", start);
  if (start < 0 || end < 0) throw new Error("DECK_SKELETON_HTML literal not found");
  // The navigation runtime it interpolates does not matter for printing: stub it.
  DECK_SKELETON_HTML = new Function(
    "DECK_PROTOCOL_V1_INLINE_RUNTIME",
    "return " + src.slice(start + "var DECK_SKELETON_HTML = ".length, end + 1),
  )("");
} else {
  ({ DECK_SKELETON_HTML } = await import(pathToFileURL(contracts).href));
}
if (typeof DECK_SKELETON_HTML !== "string") throw new Error("DECK_SKELETON_HTML not exported");
const slides = [1, 2, 3]
  .map((n) => `<section class="slide${n === 1 ? " active" : ""}" data-screen-label="0${n}"><h1>Slide ${n}</h1></section>`)
  .join("\n");
// Replace every <section class="slide …">…</section> of the skeleton with three slides.
// The first real slide is <section class="slide active" …> (comments in the framework
// mention <section class="slide"> too, so do not search for that).
const first = DECK_SKELETON_HTML.indexOf('<section class="slide active"');
const last = DECK_SKELETON_HTML.lastIndexOf("</section>");
if (first < 0 || last < first) throw new Error("no slide sections in DECK_SKELETON_HTML");
writeFileSync(out, DECK_SKELETON_HTML.slice(0, first) + slides + DECK_SKELETON_HTML.slice(last + "</section>".length));
console.log(`wrote ${out}`);
