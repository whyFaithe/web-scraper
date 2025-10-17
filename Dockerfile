# ----- Hotel Data Scraper Service (HTML-only) -----
FROM mcr.microsoft.com/playwright:v1.47.0-jammy

ENV DEBIAN_FRONTEND=noninteractive
ENV NODE_ENV=production
ENV PORT=10000
ENV PLAYWRIGHT_BROWSERS_PATH=/ms-playwright
ENV PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1

WORKDIR /app

# Small base; skip tzdata prompts
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates && \
    rm -rf /var/lib/apt/lists/*

# Only what we need: Playwright runtime; browsers are preinstalled in base image
RUN npm init -y && npm install --omit=dev playwright@1.47.0

# ---------------- server ----------------
RUN cat > /app/server.js <<'EOF'
const http = require("http");
const { chromium } = require("playwright");

/* ---------------- Config ---------------- */
const PORT = process.env.PORT || 10000;
const API_KEY = process.env.API_KEY || ""; // optional header: x-api-key
const PERSIST_DIR = "/tmp/pw-profile";     // cookie jar across requests
const MAX_ATTEMPTS = 3;

/* ---------------- Utils ---------------- */
function sendJSON(res, code, obj) {
  const body = Buffer.from(JSON.stringify(obj, null, 2));
  res.writeHead(code, { "content-type": "application/json; charset=utf-8", "content-length": body.length });
  res.end(body);
}
function sendHTML(res, code, html, extraHeaders = {}) {
  const body = Buffer.from(html || "", "utf8");
  res.writeHead(code, {
    "content-type": "text/html; charset=utf-8",
    "cache-control": "no-store",
    "content-length": body.length,
    ...extraHeaders
  });
  res.end(body);
}
function unauthorized(res){ return sendJSON(res, 401, { ok:false, error:"unauthorized" }); }

function isPrivateHost(h){
  return [/^localhost$/i,/^127\./,/^\[?::1\]?$/, /^10\./,/^192\.168\./,/^172\.(1[6-9]|2\d|3[0-1])\./,/^169\.254\./].some(re=>re.test(h));
}
function isValidHttpUrl(u){
  try{ const x=new URL(u); return /^https?:$/i.test(x.protocol) && !isPrivateHost(x.hostname); }
  catch{ return false; }
}
function isBooking(u){
  try{ return /(^|\.)booking\.com$/i.test(new URL(u).hostname); } catch { return false; }
}

/* ---------------- Playwright (persistent) ---------------- */
let ctxPromise;
async function getContext(){
  if (!ctxPromise){
    ctxPromise = chromium.launchPersistentContext(PERSIST_DIR, {
      headless: true,
      viewport: { width: 390, height: 844 }, // mobile-like to reduce heavy layouts
      userAgent: "Mozilla/5.0 (Linux; Android 14; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36",
      locale: "en-US",
      timezoneId: "America/Chicago",
      ignoreHTTPSErrors: true,
      javaScriptEnabled: true,
      bypassCSP: true,
      hasTouch: true,
      deviceScaleFactor: 2,
      args: [
        "--no-sandbox",
        "--disable-setuid-sandbox",
        "--disable-dev-shm-usage",
        "--disable-gpu",
        "--disable-features=IsolateOrigins,site-per-process"
      ]
    });
    const ctx = await ctxPromise;

    await ctx.setExtraHTTPHeaders({
      "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8",
      "Accept-Language": "en-US,en;q=0.9",
      "Upgrade-Insecure-Requests": "1",
      "Sec-Fetch-Site": "none",
      "Sec-Fetch-Mode": "navigate",
      "Sec-Fetch-User": "?1",
      "Sec-Fetch-Dest": "document"
    });

    // light stealth
    await ctx.addInitScript(() => {
      Object.defineProperty(navigator, "webdriver", { get: () => false });
      window.chrome = window.chrome || { runtime: {} };
      const orig = navigator.permissions && navigator.permissions.query;
      if (orig) {
        navigator.permissions.query = p => (p && p.name === "notifications")
          ? Promise.resolve({ state: Notification.permission })
          : orig(p);
      }
      Object.defineProperty(navigator, "languages", { get: () => ["en-US","en"] });
      Object.defineProperty(navigator, "plugins", { get: () => [1,2,3] });
    });

    // trim obvious trackers (keeps core site assets)
    await ctx.route("**/*", route => {
      const u = route.request().url();
      if (/googletagmanager|google-analytics|doubleclick|facebook\.net|hotjar|segment\.io|clarity|mixpanel|analytics\./i.test(u)) {
        return route.abort();
      }
      return route.continue();
    });
  }
  return ctxPromise;
}

async function maybeAcceptCookies(page){
  const sels = [
    "#onetrust-accept-btn-handler",
    "button#onetrust-accept-btn-handler",
    "button[aria-label='Accept']",
    "button:has-text('Accept all')"
  ];
  for (const s of sels) {
    try {
      const el = await page.$(s);
      if (el) { await el.click({ timeout: 1200 }); await page.waitForTimeout(200); break; }
    } catch {}
  }
}

async function warmBookingHome(ctx, lang="en-us"){
  const p = await ctx.newPage();
  try {
    await p.goto(`https://www.booking.com/?lang=${encodeURIComponent(lang)}`, { waitUntil:"load", timeout: 15000 });
    await maybeAcceptCookies(p);
    await p.waitForTimeout(600);
  } catch {} finally { try { await p.close(); } catch {} }
}

async function autoScroll(page, steps=4, px=1000, wait=200){
  for (let i=0;i<steps;i++){ await page.evaluate(dy => window.scrollBy(0,dy), px); await page.waitForTimeout(wait); }
}

async function waitForContent(page, timeoutMs){
  const resultsSel = "body"; // anything once DOM is there
  const wafHints = [
    'script[src*="challenge"]',
    "#challenge-container",
    'script:has-text("AwsWafIntegration")',
    'noscript:has-text("JavaScript is disabled")'
  ];
  const res = await Promise.race([
    page.waitForSelector(resultsSel, { timeout: timeoutMs, state:"attached" }).then(()=> "ok").catch(()=> null),
    ...wafHints.map(s => page.waitForSelector(s, { timeout: timeoutMs }).then(()=> "waf").catch(()=> null))
  ]);
  return res || null;
}

/* ---------------- HTML-only fetch ---------------- */
async function fetchHtmlOnly(target, timeoutMs){
  const ctx = await getContext();
  const page = await ctx.newPage();
  let attempts = 0;
  let finalUrl = target;

  try {
    if (isBooking(target)) await warmBookingHome(ctx, "en-us");

    while (attempts < MAX_ATTEMPTS) {
      attempts++;

      if (isBooking(target)) {
        await page.setExtraHTTPHeaders({ Referer: "https://www.booking.com/" });
      }

      // try a sequence of waits
      const waits = attempts === 1 ? ["domcontentloaded"] : ["load","networkidle"];
      let loaded = false;

      for (const w of waits) {
        try {
          await page.goto(finalUrl, { waitUntil: w, timeout: timeoutMs });
          await maybeAcceptCookies(page);

          const gate = await waitForContent(page, Math.max(2500, timeoutMs - 4000));
          if (gate === "waf") {
            // let their JS cook, then reload once
            try {
              await page.waitForLoadState("networkidle", { timeout: Math.min(12000, timeoutMs) });
              await page.waitForTimeout(1200);
              await page.reload({ waitUntil: "load", timeout: Math.min(12000, timeoutMs) });
            } catch {}
          }

          loaded = true;
          break;
        } catch {}
      }

      if (!loaded) continue;

      await autoScroll(page, 4, 1200, 200);

      const html = await page.content();
      finalUrl = page.url();
      return { ok:true, html, finalUrl, attempts };
    }

    return { ok:false, error:"navigation attempts exhausted", finalUrl, attempts };
  } catch (e) {
    return { ok:false, error:String(e), finalUrl, attempts };
  } finally {
    try { await page.close(); } catch {}
  }
}

/* ---------------- HTTP handler ---------------- */
async function handleScrape(qs, res){
  const target = (qs.get("url") || "").trim();
  if (!target || !isValidHttpUrl(target)) return sendJSON(res, 400, { ok:false, error:"invalid url" });

  const timeoutMs = Math.min(35000, Math.max(8000, parseInt(qs.get("timeout") || "24000", 10)));

  const r = await fetchHtmlOnly(target, timeoutMs);
  if (r.ok) {
    return sendHTML(res, 200, r.html, { "x-final-url": r.finalUrl, "x-attempts": String(r.attempts || 1) });
  } else {
    return sendJSON(res, 500, r);
  }
}

const server = http.createServer(async (req, res) => {
  try{
    const url = new URL(req.url, `http://${req.headers.host}`);

    if (API_KEY){
      const key = req.headers["x-api-key"];
      if (key !== API_KEY) return unauthorized(res);
    }

    if (url.pathname === "/health" || url.pathname === "/status"){
      return sendJSON(res, 200, { ok:true });
    }
    if (url.pathname === "/scrape"){
      return handleScrape(url.searchParams, res);
    }
    return sendJSON(res, 404, { ok:false, error:"not found" });
  } catch (e){
    return sendJSON(res, 500, { ok:false, error:String(e) });
  }
});

server.listen(PORT, () => console.log("hotel scraper (HTML-only) listening on :"+PORT));
EOF

EXPOSE 10000

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s \
  CMD node -e "fetch('http://127.0.0.1:'+process.env.PORT+'/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"

CMD ["node","/app/server.js"]
