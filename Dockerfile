# ----- Hotel Data Scraper Service (bot-resilient) -----
FROM mcr.microsoft.com/playwright:v1.47.0-jammy

ENV DEBIAN_FRONTEND=noninteractive
ENV NODE_ENV=production
ENV PORT=10000
ENV PLAYWRIGHT_BROWSERS_PATH=/ms-playwright
ENV PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1

WORKDIR /app

# keep image slim; we only need certs
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates && \
    rm -rf /var/lib/apt/lists/*

# provide playwright + cheerio so require('playwright') works at runtime
RUN npm init -y && npm install --omit=dev playwright@1.47.0 cheerio@1.0.0-rc.12

# ------------ server ------------
RUN cat > /app/server.js <<'EOF'
const http = require("http");
const { chromium } = require("playwright");
const cheerio = require("cheerio");

const PORT = process.env.PORT || 10000;
const API_KEY = process.env.API_KEY || "";

/* ----------------- Browser factory (reused) ----------------- */
let browserPromise;
async function getBrowser(){
  if (!browserPromise){
    browserPromise = chromium.launch({
      headless: true,
      args: [
        "--no-sandbox",
        "--disable-setuid-sandbox",
        "--disable-dev-shm-usage",
        "--disable-gpu",
        "--disable-features=IsolateOrigins,site-per-process"
      ]
    });
  }
  return browserPromise;
}

/* ----------------- HTTP helpers ----------------- */
function sendJSON(res, code, obj){
  const body = Buffer.from(JSON.stringify(obj, null, 2));
  res.writeHead(code, {"content-type":"application/json; charset=utf-8","content-length":body.length});
  res.end(body);
}
function unauthorized(res){ return sendJSON(res, 401, {ok:false, error:"unauthorized"}); }
function isPrivateHost(h){ return [/^localhost$/i,/^127\./,/^\[?::1\]?$/, /^10\./,/^192\.168\./,/^172\.(1[6-9]|2\d|3[0-1])\./,/^169\.254\./].some(re=>re.test(h)); }
function isValidHttpUrl(u){ try{ const x=new URL(u); return /^https?:$/.test(x.protocol) && !isPrivateHost(x.hostname); } catch { return false; } }

/* ----------------- Light stealth / real headers ----------------- */
const DESKTOP_UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36";
const ANDROID_UA = "Mozilla/5.0 (Linux; Android 14; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36";
const IPHONE_UA  = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Mobile/15E148 Safari/604.1";

async function applyStealth(page){
  await page.addInitScript(() => {
    Object.defineProperty(navigator, "webdriver", {get: () => false});
    window.chrome = window.chrome || { runtime: {} };
    const origQuery = window.navigator.permissions?.query;
    if (origQuery) {
      window.navigator.permissions.query = (p) =>
        p && p.name === "notifications"
          ? Promise.resolve({ state: Notification.permission })
          : origQuery(p);
    }
    Object.defineProperty(navigator, "plugins",   { get: () => [1,2,3] });
    Object.defineProperty(navigator, "languages", { get: () => ["en-US","en"] });
  });
}

/* ----------------- Context factory ----------------- */
async function makeContext({
  ua = ANDROID_UA,
  lang = "en-US,en;q=0.9",
  w = 1200,
  h = 800,
  blockAssets = true
} = {}){
  const ctx = await (await getBrowser()).newContext({
    viewport: { width: w, height: h },
    userAgent: ua,
    locale: (lang.split(",")[0] || "en-US"),
    deviceScaleFactor: 1,
    bypassCSP: true,
    ignoreHTTPSErrors: true,
    javaScriptEnabled: true,
    // Service workers sometimes interfere with token flows; block them.
    serviceWorkers: "block",
    extraHTTPHeaders: {
      "Accept-Language": lang,
      "Upgrade-Insecure-Requests": "1",
      "Sec-Fetch-Site": "none",
      "Sec-Fetch-Mode": "navigate",
      "Sec-Fetch-User": "?1",
      "Sec-Fetch-Dest": "document"
    }
  });

  if (blockAssets){
    await ctx.route("**/*", route => {
      const r = route.request();
      const type = r.resourceType();
      if (type === "image" || type === "font" || type === "media") return route.abort();
      return route.continue();
    });
  }

  return ctx;
}

/* ----------------- Booking-specific loader ----------------- */
/** Returns { ok, finalUrl, html, attempts, challengeDetected } */
async function loadBookingPage(targetUrl, { timeoutMs = 28000 } = {}){
  // Try Android Chrome first, then iPhone Safari. These often see lighter bot friction.
  const attempts = [
    { ua: ANDROID_UA, wait: "domcontentloaded" },
    { ua: IPHONE_UA,  wait: "load" }
  ];

  for (let i = 0; i < attempts.length; i++){
    const { ua, wait } = attempts[i];
    let ctx, page, challengeDetected = false;
    try{
      ctx = await makeContext({ ua, blockAssets: false }); // allow JS/CSS
      page = await ctx.newPage();
      await applyStealth(page);

      // 1) Warm homepage to set basic cookies (lang etc.)
      await page.goto("https://www.booking.com/?lang=en-us", { waitUntil: "domcontentloaded", timeout: Math.min(8000, timeoutMs) }).catch(()=>{});

      // 2) Go to the target search URL
      await page.goto(targetUrl, { waitUntil: wait, timeout: timeoutMs });

      // If AWS WAF challenge is present, allow it to complete (it usually auto-redirects)
      const sawChallenge = await page.locator('script[src*="__challenge"], script:has-text("AwsWafIntegration")').first().isVisible({ timeout: 1000 }).catch(()=>false);
      if (sawChallenge) {
        challengeDetected = true;
        // wait for URL change or results present
        const prev = page.url();
        await Promise.race([
          page.waitForURL((u) => u !== prev, { timeout: 12000 }).catch(()=>{}),
          page.waitForSelector('div[data-testid="property-card"]', { timeout: 12000 }).catch(()=>{})
        ]);
      }

      // Handle OneTrust cookie banner quickly (Accept all)
      const oneTrustAccept = page.locator('#onetrust-accept-btn-handler, button:has-text("Accept")').first();
      if (await oneTrustAccept.isVisible({ timeout: 1000 }).catch(()=>false)) {
        await oneTrustAccept.click({ timeout: 2000 }).catch(()=>{});
        await page.waitForTimeout(400);
      }

      // Wait for search results to render
      await page.waitForSelector('div[data-testid="property-card"], #search_results_table, [aria-label="Search results"]', { timeout: 12000 });

      // Small scroll to trigger lazy cards
      await page.evaluate(() => { window.scrollBy(0, 1200); });
      await page.waitForTimeout(600);

      // Gather HTML
      const html = await page.content();
      const finalUrl = page.url();
      const looksOk =
        /data-testid="property-card"/i.test(html) ||
        /id="search_results_table"/i.test(html) ||
        /aria-label="Search results"/i.test(html);

      if (looksOk) {
        return { ok: true, finalUrl, html, attempts: i+1, challengeDetected };
      }

      // If not ok, try next UA
      await page.close().catch(()=>{});
      await ctx.close().catch(()=>{});
    } catch (e){
      // try the next attempt
      try { if (page) await page.close(); } catch {}
      try { if (ctx) await ctx.close(); } catch {}
      if (i === attempts.length - 1) {
        return { ok: false, finalUrl: targetUrl, html: "", attempts: i+1, challengeDetected: false, error: String(e) };
      }
    }
  }

  // If we fall through (shouldn't), return not ok
  return { ok: false, finalUrl: targetUrl, html: "", attempts: attempts.length, challengeDetected: false };
}

/* ----------------- Generic loader (non-Booking) ----------------- */
async function loadGeneric(targetUrl, { timeoutMs = 20000 } = {}){
  let ctx, page;
  try{
    ctx = await makeContext({ ua: DESKTOP_UA });
    page = await ctx.newPage();
    await applyStealth(page);

    await page.goto(targetUrl, { waitUntil: "domcontentloaded", timeout: timeoutMs });
    await page.waitForTimeout(800);
    await page.waitForLoadState("networkidle", { timeout: 8000 }).catch(()=>{});
    const html = await page.content();
    const finalUrl = page.url();
    return { ok: true, finalUrl, html };
  } catch (e){
    return { ok: false, finalUrl: targetUrl, html: "", error: String(e) };
  } finally {
    try { if (page) await page.close(); } catch {}
    try { if (ctx) await ctx.close(); } catch {}
  }
}

/* ----------------- Extractors ----------------- */
function extractBookingSearchResults(html, searchUrl){
  const $ = cheerio.load(html);
  const results = [];

  $('div[data-testid="property-card"]').each((i, el) => {
    const $card = $(el);

    const title = $card.find('div[data-testid="title"]').text().trim()
      || $card.find('[data-testid="property-card-name"]').text().trim();

    // hotel URL
    const rel = $card.find('a[data-testid="title-link"]').attr('href')
      || $card.find('a[data-testid="availability-cta"]').attr('href');
    let hotelUrl = null;
    if (rel) {
      try {
        const abs = new URL(rel, 'https://www.booking.com').href;
        const u = new URL(abs);
        hotelUrl = u.origin + u.pathname; // strip params
      } catch {}
    }

    // rating
    let rating = null;
    const scoreNode = $card.find('[data-testid="review-score"] [aria-label], [data-testid="review-score"] div').first();
    const scoreTxt = (scoreNode.attr('aria-label') || scoreNode.text() || "").trim();
    const mScore = scoreTxt.match(/([0-9]+(?:\.[0-9])?)/);
    if (mScore) rating = parseFloat(mScore[1]);

    // reviews
    let reviewCount = null;
    const reviewsTxt = $card.find('[data-testid="review-score"]').text();
    const mReviews = reviewsTxt.match(/([\d,]+)\s+reviews?/i);
    if (mReviews) reviewCount = parseInt(mReviews[1].replace(/,/g, ''), 10);

    // price (if visible)
    const price = $card.find('span[data-testid="price-and-discounted-price"]').text().trim() ||
                  $card.find('[data-testid="price-for-x-nights"]').text().trim() || null;

    const location = $card.find('span[data-testid="address"]').text().trim() || null;

    if (title) {
      results.push({ title, url: hotelUrl, rating, reviewCount, price: price || null, location });
    }
  });

  return { searchUrl, resultCount: results.length, hotels: results };
}

function extractBookingHotelDetails(html, url){
  const $ = cheerio.load(html);
  const data = {
    url,
    title: null,
    address: null,
    phone: null,
    rating: null,
    reviewCount: null,
    description: null,
    amenities: [],
    price: null
  };

  data.title =
    $('h2[data-testid="property-name"]').text().trim() ||
    $('h1').first().text().trim() ||
    $('title').text().trim() || null;

  data.address =
    $('span[data-node_tt_id="location_score_tooltip"]').text().trim() ||
    $('[data-testid="address"]').text().trim() ||
    $('p[data-capla-component="b-property-web-property-page/PropertyHeaderAddress"]').text().trim() || null;

  // rating + reviews
  const scoreWrap = $('[data-testid="review-score-component"], [data-testid="review-score"]');
  const scoreTxt = scoreWrap.find('div').first().text().trim();
  const mScore = scoreTxt.match(/([0-9]+(?:\.[0-9])?)/);
  if (mScore) data.rating = parseFloat(mScore[1]);

  const reviewTxt = scoreWrap.text();
  const mReviews = reviewTxt.match(/([\d,]+)\s+reviews?/i);
  if (mReviews) data.reviewCount = parseInt(mReviews[1].replace(/,/g,''),10);

  data.description = $('p[data-testid="property-description"]').first().text().trim() || null;

  $('[data-testid="property-most-popular-facilities"] [data-testid="facility-card"]').each((i, el) => {
    const t = cheerio(el).text().trim();
    if (t && t.length < 100) data.amenities.push(t);
  });

  // structured data
  $('script[type="application/ld+json"]').each((i, el) => {
    try {
      const json = JSON.parse($(el).html());
      if (json.telephone && !data.phone) data.phone = json.telephone;
      if (json.address && !data.address) {
        if (typeof json.address === "string") data.address = json.address;
        else data.address = [json.address.streetAddress, json.address.addressLocality, json.address.addressRegion, json.address.postalCode].filter(Boolean).join(", ");
      }
    } catch {}
  });

  return data;
}

function extractGenericHotelData(html, url){
  const $ = cheerio.load(html);
  const data = {
    url,
    title: $('title').text().trim() || $('h1').first().text().trim() || null,
    address: null,
    phone: null,
    email: null,
    bookingLinks: [],
    structuredData: []
  };

  $('script[type="application/ld+json"]').each((i, el) => {
    try {
      const json = JSON.parse($(el).html());
      data.structuredData.push(json);
      const t = Array.isArray(json) ? json : [json];
      for (const item of t) {
        if (item['@type'] === 'Hotel' || item['@type'] === 'LodgingBusiness') {
          if (item.address) {
            if (typeof item.address === "string") data.address = item.address;
            else data.address = [item.address.streetAddress, item.address.addressLocality, item.address.addressRegion, item.address.postalCode].filter(Boolean).join(", ");
          }
          if (item.telephone) data.phone = item.telephone;
          if (item.email) data.email = item.email;
        }
      }
    } catch {}
  });

  const bookingDomains = ['booking.com','expedia.com','hotels.com','tripadvisor.com','airbnb.com','vrbo.com','agoda.com','kayak.com','priceline.com'];
  $('a[href]').each((i, el) => {
    const href = $(el).attr('href');
    if (href && bookingDomains.some(d => href.includes(d))){
      try {
        const full = new URL(href, url).href;
        if (!data.bookingLinks.includes(full)) data.bookingLinks.push(full);
      } catch {}
    }
  });

  const bodyText = $('body').text();
  if (!data.address){
    const m = bodyText.match(/\d+\s+[^\n,]+(?:Street|St|Avenue|Ave|Road|Rd|Boulevard|Blvd|Drive|Dr|Lane|Ln|Way|Court|Ct|Plaza|Parkway|Pkwy)[^\n,]*,\s*[A-Za-z .'-]+,\s*[A-Z]{2}\s+\d{5}/);
    if (m) data.address = m[0].trim();
  }
  if (!data.phone){
    const m = bodyText.match(/(?:\+?1[-.\s]?)?\(?([0-9]{3})\)?[-.\s]?([0-9]{3})[-.\s]?([0-9]{4})/);
    if (m) data.phone = m[0].trim();
  }
  if (!data.email){
    const m = bodyText.match(/[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}/);
    if (m) data.email = m[0].trim();
  }

  return data;
}

/* ----------------- Handler ----------------- */
async function handleScrape(qs, res){
  const target = (qs.get("url") || "").trim();
  if (!target || !isValidHttpUrl(target)) return sendJSON(res, 400, {ok:false, error:"invalid url"});

  const timeoutMs   = Math.min(40000, Math.max(6000, parseInt(qs.get("timeout") || "28000", 10)));
  const includeHtml = (qs.get("html") || "0") === "1";
  const mode        = (qs.get("mode") || "auto").toLowerCase(); // "auto" | "search" | "details"

  let finalLoad;
  const isBooking = /(^|\.)booking\.com$/i.test(new URL(target).hostname);

  if (isBooking) {
    finalLoad = await loadBookingPage(target, { timeoutMs });
  } else {
    finalLoad = await loadGeneric(target, { timeoutMs });
  }

  if (!finalLoad.ok) {
    return sendJSON(res, 502, { ok:false, error: finalLoad.error || "load failed", finalUrl: finalLoad.finalUrl, attempts: finalLoad.attempts || 1 });
  }

  const html = finalLoad.html || "";
  const finalUrl = finalLoad.finalUrl || target;

  // Choose extractor
  let data;
  if (mode === "search" || (mode === "auto" && isBooking && /\/searchresults\.html/.test(finalUrl))) {
    data = extractBookingSearchResults(html, finalUrl);
  } else if (mode === "details" || (mode === "auto" && isBooking && /\/hotel\//.test(finalUrl))) {
    data = extractBookingHotelDetails(html, finalUrl);
  } else {
    data = extractGenericHotelData(html, finalUrl);
  }

  const out = {
    ok: true,
    finalUrl,
    attempts: finalLoad.attempts || 1,
    challengeDetected: !!finalLoad.challengeDetected,
    ...data
  };
  if (includeHtml) out.html = html;

  return sendJSON(res, 200, out);
}

/* ----------------- HTTP server ----------------- */
const server = http.createServer(async (req, res) => {
  try{
    const url = new URL(req.url, `http://${req.headers.host}`);

    // optional API key
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

server.listen(PORT, () => console.log("hotel scraper listening on :"+PORT));
EOF

EXPOSE 10000

# healthcheck
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s \
  CMD node -e "fetch('http://127.0.0.1:'+process.env.PORT+'/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"

CMD ["node","/app/server.js"]
