import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

async function render() {
  const workerUrl = new URL("../dist/server/index.js", import.meta.url);
  workerUrl.searchParams.set("test", `${process.pid}-${Date.now()}`);
  const { default: worker } = await import(workerUrl.href);

  return worker.fetch(
    new Request("http://localhost/", {
      headers: { accept: "text/html" },
    }),
    {
      ASSETS: {
        fetch: async () => new Response("Not found", { status: 404 }),
      },
    },
    {
      waitUntil() {},
      passThroughOnException() {},
    },
  );
}

test("server-renders the Clarity 6 slide deck", async () => {
  const response = await render();
  assert.equal(response.status, 200);
  assert.match(response.headers.get("content-type") ?? "", /^text\/html\b/i);

  const html = await response.text();
  assert.match(html, /A clean engine/);
  assert.match(html, /contract-call\?/);
  assert.match(html, /clarity-v6\/src\/vm\/functions\/database\.rs/);
  assert.match(html, /Not every epoch-gated change becomes an engine/);
  assert.match(html, /aria-label="Slide navigation"/);
  assert.match(html, /aria-label="Slide 9:/);
  assert.doesNotMatch(html, /aria-label="Slide 10:/);
});

test("includes keyboard, touch, and overview interactions", async () => {
  const [page, css, layout] = await Promise.all([
    readFile(new URL("../app/page.tsx", import.meta.url), "utf8"),
    readFile(new URL("../app/globals.css", import.meta.url), "utf8"),
    readFile(new URL("../app/layout.tsx", import.meta.url), "utf8"),
  ]);

  assert.match(page, /ArrowRight/);
  assert.match(page, /PageDown/);
  assert.match(page, /onTouchStart/);
  assert.match(page, /setOverview/);
  assert.match(page, /totalSlides = slideTitles\.length/);
  assert.match(css, /\.slide\.active/);
  assert.match(css, /prefers-reduced-motion/);
  assert.match(layout, /Technical Slide Deck/);
});
