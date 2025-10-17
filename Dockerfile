# ----- Hotel Data Scraper Service (anti-bot tuned) -----
FROM mcr.microsoft.com/playwright:v1.47.0-jammy

ENV DEBIAN_FRONTEND=noninteractive
ENV NODE_ENV=production
ENV PORT=10000
ENV PLAYWRIGHT_BROWSERS_PATH=/ms-playwright
ENV PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1

WORKDIR /app

# Small base install; avoid tzdata to skip prompts
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates && \
    rm -rf /var/lib/apt/lists/*

# Provide the 'playwright' runtime + cheerio (used for non-Booking generics)
RUN npm init -y && npm install --omit=dev playwright@1.47.0 cheerio@1.0.0-rc.12

# Write the whole server
RUN cat > /app/server.js <<'EOF'
const http = require("http");
const cheerio = require("cheerio");
const { chromium } = require("playwright");

/* ---------------- Config ---------------- */
const PORT = process.env.PORT || 10000;
const API_KEY = process.env.API_KEY || ""; // optional header: x-api-key
const PERSIST_DIR = "/tmp/pw-profile";     // persistent context for cookies
const MAX_ATTEMPTS = 3;

/* ---------------- Playwright context (persistent) ---------------- */
let ctxPromise;
async function getContext() {
  if (!ctxPromise) {
    ctxPromise = chromium.launchPersistentContext(PERSIST_DIR, {
      headless: true,
      viewport: { width: 390, height: 844 }, // mobile viewport (Pixel-ish)
      userAgent:
        "Mozilla/5.0 (Linux; Android 14; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36",
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
        "--disable-features=IsolateOrigins,site-per-process",
      ],
    });

    const ctx = await ctxPromise;

    // Realistic extra headers (helps both WAF & SSR pathing)
    await ctx.setExtraHTTPHeaders({
      "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8",
      "Accept-Language": "en-US,en;q=0.9",
      "Upgrade-Insecure-Requests": "1",
      "Sec-Fetch-Site": "none",
      "Sec-Fetch-Mode": "navigate",
      "Sec-Fetch-User": "?1",
      "Sec-Fetch-Dest": "document",
    });

    // Light stealth patches to reduce headless signals
    await ctx.addInitScript(() => {
      Object.defineProperty(navigator, "webdriver", { get: () => false });
      window.chrome = window.chrome || { runtime: {} };
      const origQuery = window.navigator.permissions?.query;
      if (origQuery) {
        window.navigator.permissions.query = (p) =>
          p && p.name === "notifications"
            ? Promise.resolve({ state: Notification.permission })
            : origQuery(p);
      }
      Object.defineProperty(navigator, "languages", { get: () => ["en-US", "en"] });
      Object.defineProperty(navigator, "plugins", { get: () => [1, 2, 3] });
    });

    // Trim noise (ads/analytics) to load faster, but keep core domains
    await ctx.route("**/*", (route) => {
      const u = route.request().url();
      if (
        /googletagmanager|google-analytics|doubleclick|facebook\.net|hotjar|mixpanel|segment\.io|clarity|analytics\./i.test(
          u
        )
      ) {
        return route.abort();
      }
      return route.continue();
    });
  }
  return ctxPromise;
}

/* ---------------- Utilities ---------------- */
function sendJSON(res, code, obj) {
  const body = Buffer.from(JSON.stringify(obj, null, 2));
  res.writeHead(code, {
    "content-type": "application/json; charset=utf-8",
    "content-length": body.length,
  });
  res.end(body);
}

function unauthorized(res) {
  return sendJSON(res, 401, { ok: false, error: "unauthorized" });
}
function isPrivateHost(h) {
  return [/^localhost$/i, /^127\./, /^\[?::1\]?$/, /^10\./, /^192\.168\./, /^172\.(1[6-9]|2\d|3[0-1])\./, /^169\.254\./].some(
    (re) => re.test(h)
  );
}
function isValidHttpUrl(u) {
  try {
    const x = new URL(u);
    return /^https?:$/i.test(x.protocol) && !isPrivateHost(x.hostname);
  } catch {
    return false;
  }
}
function isBookingSearchUrl(u) {
  try {
    const { hostname, pathname } = new URL(u);
    return /(^|\.)booking\.com$/i.test(hostname) && /^\/searchresults\.html$/i.test(pathname);
  } catch {
    return false;
  }
}
function isBookingHotelUrl(u) {
  try {
    const { hostname, pathname } = new URL(u);
    return /(^|\.)booking\.com$/i.test(hostname) && /\/hotel\//i.test(pathname);
  } catch {
    return false;
  }
}

async function maybeAcceptCookies(page) {
  // Accept OneTrust cookie banner if present
  const selectors = [
    "#onetrust-accept-btn-handler",
    "button#onetrust-accept-btn-handler",
    "button[aria-label='Accept']",
    "button:has-text('Accept all')",
  ];
  for (const sel of selectors) {
    const el = await page.$(sel);
    if (el) {
      try {
        await el.click({ timeout: 1500 });
        await page.waitForTimeout(300);
        break;
      } catch {}
    }
  }
}

async function warmBookingHome(ctx, lang = "en-us") {
  const p = await ctx.newPage();
  try {
    await p.goto(`https://www.booking.com/?lang=${encodeURIComponent(lang)}`, { waitUntil: "load", timeout: 15000 });
    await maybeAcceptCookies(p);
    await p.waitForTimeout(600);
  } catch {}
  finally {
    try { await p.close(); } catch {}
  }
}

async function waitForResultsOrChallenge(page, timeoutMs) {
  const t0 = Date.now();
  const resultsSel = 'div[data-testid="property-card"], #search_results_table, [aria-label="Search results"]';
  const wafHints = [
    'script[src*="challenge"]',
    "#challenge-container",
    'script:has-text("AwsWafIntegration")',
    'noscript:has-text("JavaScript is disabled")'
  ];

  // Race: either results appear, or WAF markers appear.
  const winner = await Promise.race([
    page.waitForSelector(resultsSel, { timeout: timeoutMs, state: "visible" }).then(() => "results").catch(() => null),
    ...wafHints.map((s) =>
      page.waitForSelector(s, { timeout: timeoutMs }).then(() => "challenge").catch(() => null)
    ),
  ]);

  if (winner === "results") return { ok: true, challenge: false, elapsed: Date.now() - t0 };

  if (winner === "challenge") {
    // Let their script set cookies & auto-redirect
    try {
      await page.waitForLoadState("networkidle", { timeout: Math.min(15000, timeoutMs) });
      await page.waitForTimeout(1200);
    } catch {}
    // Check once more for results
    const got = await page.$('div[data-testid="property-card"]');
    if (got) return { ok: true, challenge: true, elapsed: Date.now() - t0 };
  }

  return { ok: false, challenge: winner === "challenge", elapsed: Date.now() - t0 };
}

async function autoScroll(page, steps = 6, px = 1000, wait = 250) {
  for (let i = 0; i < steps; i++) {
    await page.evaluate((dy) => window.scrollBy(0, dy), px);
    await page.waitForTimeout(wait);
  }
}

/* ---------------- Extractors (DOM-first) ---------------- */
async function extractSearchCardsFromDom(page) {
  return await page.evaluate(() => {
    const out = [];
    const cards = document.querySelectorAll('div[data-testid="property-card"]');
    cards.forEach((card) => {
      const title =
        card.querySelector('[data-testid="title"]')?.textContent?.trim() ||
        card.querySelector("h3,h2,h1")?.textContent?.trim() ||
        null;

      let url = card.querySelector('a[data-testid="title-link"]')?.href || null;
      if (url) {
        try {
          const u = new URL(url, location.origin);
          url = u.origin + u.pathname; // strip params
        } catch {}
      }

      const address =
        card.querySelector('[data-testid="address"]')?.textContent?.trim() ||
        card.querySelector('[data-testid="location"]')?.textContent?.trim() ||
        null;

      // Rating can be in different sub-elements
      let rating = null;
      const scoreEl =
        card.querySelector('[data-testid="review-score"]') ||
        card.querySelector('[aria-label*="score"]') ||
        card.querySelector('[data-testid*="score"]');

      if (scoreEl) {
        const txt = scoreEl.textContent.replace(",", ".");
        const m = txt.match(/(\d+(?:\.\d+)?)/);
        if (m) rating = parseFloat(m[1]);
      }

      // Reviews: find a number near 'reviews'
      let reviewCount = null;
      const txt = card.textContent || "";
      const rm = txt.match(/([\d,.]+)\s*reviews?/i);
      if (rm) reviewCount = parseInt(rm[1].replace(/[^\d]/g, ""), 10);

      // Price: Booking often puts formatted price in this span
      let price =
        card.querySelector('span[data-testid="price-and-discounted-price"]')?.textContent?.trim() ||
        card.querySelector('[data-testid*="price"]')?.textContent?.trim() ||
        null;

      out.push({ title, url, rating, reviewCount, price, location: address });
    });
    return out;
  });
}

async function extractHotelDetailsFromDom(page) {
  return await page.evaluate(() => {
    const clean = (s) => (s || "").replace(/\s+/g, " ").trim();
    const data = {
      title:
        clean(document.querySelector('h2[data-testid="property-name"]')?.textContent) ||
        clean(document.querySelector("h1")?.textContent) ||
        null,
      address:
        clean(document.querySelector('span[data-node_tt_id="location_score_tooltip"]')?.textContent) ||
        clean(document.querySelector('[data-testid="address"]')?.textContent) ||
        null,
      rating: null,
      reviewCount: null,
      description:
        clean(document.querySelector('p[data-testid="property-description"]')?.textContent) || null,
      amenities: [],
      phone: null,
    };

    const scoreBlock =
      document.querySelector('[data-testid="review-score-component"]') ||
      document.querySelector('[data-testid="review-score"]');
    if (scoreBlock) {
      const txt = clean(scoreBlock.textContent).replace(",", ".");
      const m = txt.match(/(\d+(?:\.\d+)?)/);
      if (m) data.rating = parseFloat(m[1]);
      const rm = txt.match(/([\d,.]+)\s*reviews?/i);
      if (rm) data.reviewCount = parseInt(rm[1].replace(/[^\d]/g, ""), 10);
    }

    document
      .querySelectorAll('[data-testid="property-most-popular-facilities"] [data-testid="property-most-popular-facility"]')
      .forEach((n) => {
        const t = clean(n.textContent);
        if (t && t.length < 80) data.amenities.push(t);
      });

    // JSON-LD
    document.querySelectorAll('script[type="application/ld+json"]').forEach((s) => {
      try {
        const j = JSON.parse(s.textContent || "{}");
        if (j && typeof j === "object") {
          const tel = j.telephone || j.phone || null;
          if (tel && !data.phone) data.phone = tel;
          const addr = j.address;
          if (!data.address && addr) {
            if (typeof addr === "string") data.address = clean(addr);
            else if (addr.streetAddress) {
              data.address = [addr.streetAddress, addr.addressLocality, addr.addressRegion, addr.postalCode]
                .filter(Boolean)
                .join(", ");
            }
          }
        }
      } catch {}
    });

    // Fallback regexes
    if (!data.phone) {
      const m = (document.body.textContent || "").match(
        /(?:\+?1[-.\s]?)?\(?(\d{3})\)?[-.\s]?(\d{3})[-.\s]?(\d{4})/
      );
      if (m) data.phone = m[0];
    }

    if (!data.address) {
      const t = document.body.textContent || "";
      const m = t.match(
        /\d+\s+[\w\s]+(?:Street|St|Avenue|Ave|Road|Rd|Boulevard|Blvd|Drive|Dr|Lane|Ln|Way|Court|Ct|Plaza|Parkway|Pkwy)[,\s]+[\w\s]+,\s*[A-Z]{2}\s+\d{5}/i
      );
      if (m) data.address = clean(m[0]);
    }

    return data;
  });
}

/* ---------------- Main handlers ---------------- */
async function scrapeBookingSearch(url, timeoutMs) {
  const ctx = await getContext();
  let page = await ctx.newPage();
  let attempts = 0;
  let challengeDetected = false;
  let finalUrl = url;

  try {
    // Warm homepage once per attempt 0 to pick up cookies
    if (attempts === 0) await warmBookingHome(ctx, "en-us");

    while (attempts < MAX_ATTEMPTS) {
      attempts++;

      // Always set a referer that looks natural
      await page.setExtraHTTPHeaders({ Referer: "https://www.booking.com/" });

      // Try progressively stronger waits
      const waitModes = attempts === 1 ? ["domcontentloaded"] : ["load", "networkidle"];
      let loaded = false;

      for (const wm of waitModes) {
        try {
          await page.goto(finalUrl, { waitUntil: wm, timeout: timeoutMs });
          await maybeAcceptCookies(page);
          const gate = await waitForResultsOrChallenge(page, Math.max(3000, timeoutMs - 4000));
          challengeDetected = challengeDetected || gate.challenge;
          if (gate.ok) {
            loaded = true;
            break;
          }
        } catch {}
      }

      if (!loaded) {
        // Gentle reload, then try again
        try { await page.reload({ waitUntil: "load", timeout: Math.min(10000, timeoutMs) }); } catch {}
        continue;
      }

      // Scroll a bit to allow lazy-loaded cards to mount
      await autoScroll(page, 4, 1200, 250);

      const hotels = await extractSearchCardsFromDom(page);
      return {
        ok: true,
        finalUrl: page.url(),
        attempts,
        challengeDetected,
        resultCount: hotels.length,
        hotels,
      };
    }

    // If loop ends without return
    return {
      ok: false,
      error: `Timed out waiting for search results after ${attempts} attempts`,
      finalUrl,
      attempts,
      challengeDetected,
    };
  } catch (e) {
    return { ok: false, error: String(e), finalUrl, attempts, challengeDetected };
  } finally {
    try { await page.close(); } catch {}
  }
}

async function scrapeBookingHotel(url, timeoutMs) {
  const ctx = await getContext();
  const page = await ctx.newPage();
  let attempts = 0;
  let challengeDetected = false;
  let finalUrl = url;

  try {
    if (attempts === 0) await warmBookingHome(ctx, "en-us");

    while (attempts < MAX_ATTEMPTS) {
      attempts++;

      await page.setExtraHTTPHeaders({ Referer: "https://www.booking.com/" });

      const waitModes = attempts === 1 ? ["domcontentloaded"] : ["load", "networkidle"];
      let loaded = false;

      for (const wm of waitModes) {
        try {
          await page.goto(finalUrl, { waitUntil: wm, timeout: timeoutMs });
          await maybeAcceptCookies(page);
          const gate = await waitForResultsOrChallenge(page, Math.max(3000, timeoutMs - 4000));
          challengeDetected = challengeDetected || gate.challenge;
          if (gate.ok) { loaded = true; break; }
        } catch {}
      }

      if (!loaded) { try { await page.reload({ waitUntil: "load", timeout: Math.min(10000, timeoutMs) }); } catch {} ; continue; }

      await autoScroll(page, 3, 1000, 250);
      const details = await extractHotelDetailsFromDom(page);
      return { ok: true, finalUrl: page.url(), attempts, challengeDetected, ...details };
    }

    return { ok: false, error: `Timed out on hotel page after ${attempts} attempts`, finalUrl, attempts, challengeDetected };
  } catch (e) {
    return { ok: false, error: String(e), finalUrl, attempts, challengeDetected };
  } finally {
    try { await page.close(); } catch {}
  }
}

async function scrapeGeneric(url, timeoutMs, includeHtml) {
  const ctx = await getContext();
  const page = await ctx.newPage();

  try {
    await page.goto(url, { waitUntil: "load", timeout: timeoutMs });
    await page.waitForTimeout(600);
    const html = await page.content();

    // Basic structured scrape via Cheerio
    const $ = cheerio.load(html);
    const data = {
      url,
      title: $("title").text().trim() || $("h1").first().text().trim() || null,
      address: null,
      phone: null,
      email: null,
      bookingLinks: [],
    };

    $("script[type='application/ld+json']").each((_, el) => {
      try {
        const j = JSON.parse($(el).text());
        const maybeHotel = Array.isArray(j) ? j : [j];
        for (const item of maybeHotel) {
          if (item && typeof item === "object") {
            if (!data.phone && (item.telephone || item.phone)) data.phone = item.telephone || item.phone;
            if (!data.email && item.email) data.email = item.email;
            const addr = item.address;
            if (!data.address && addr) {
              if (typeof addr === "string") data.address = addr.trim();
              else if (addr.streetAddress) {
                data.address = [addr.streetAddress, addr.addressLocality, addr.addressRegion, addr.postalCode]
                  .filter(Boolean)
                  .join(", ");
              }
            }
          }
        }
      } catch {}
    });

    const bookingDomains = [
      "booking.com",
      "expedia.com",
      "hotels.com",
      "tripadvisor.com",
      "airbnb.com",
      "vrbo.com",
      "agoda.com",
    ];
    $("a[href]").each((_, a) => {
      const href = $(a).attr("href");
      if (href && bookingDomains.some((d) => href.includes(d))) {
        try {
          const full = new URL(href, url).href;
          if (!data.bookingLinks.includes(full)) data.bookingLinks.push(full);
        } catch {}
      }
    });

    if (!data.address) {
      const t = $("body").text();
      const m = t.match(
        /\d+\s+[\w\s]+(?:Street|St|Avenue|Ave|Road|Rd|Boulevard|Blvd|Drive|Dr|Lane|Ln|Way|Court|Ct|Plaza|Parkway|Pkwy)[,\s]+[\w\s]+,\s*[A-Z]{2}\s+\d{5}/i
      );
      if (m) data.address = m[0].trim();
    }
    if (!data.phone) {
      const t = $("body").text();
      const m = t.match(/(?:\+?1[-.\s]?)?\(?(\d{3})\)?[-.\s]?(\d{3})[-.\s]?(\d{4})/);
      if (m) data.phone = m[0];
    }
    if (!data.email) {
      const t = $("body").text();
      const m = t.match(/[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}/);
      if (m) data.email = m[0];
    }

    const out = { ok: true, ...data };
    if (includeHtml) out.html = html;
    return out;
  } catch (e) {
    return { ok: false, error: String(e), url };
  } finally {
    try { await page.close(); } catch {}
  }
}

/* ---------------- HTTP handler ---------------- */
async function handleScrape(qs, res) {
  const target = (qs.get("url") || "").trim();
  if (!target || !isValidHttpUrl(target)) return sendJSON(res, 400, { ok: false, error: "invalid url" });

  const timeoutMs = Math.min(35000, Math.max(8000, parseInt(qs.get("timeout") || "24000", 10)));
  const includeHtml = (qs.get("html") || "0") === "1";
  const mode = (qs.get("mode") || "auto").toLowerCase();

  try {
    if (mode === "search" || (mode === "auto" && isBookingSearchUrl(target))) {
      const r = await scrapeBookingSearch(target, timeoutMs);
      if (includeHtml && r.ok) {
        // lightweight: only first 100k to avoid giant payloads
        r.html = (await (await (await getContext()).newPage()).goto(target)).text?.slice?.(0, 100000);
      }
      return sendJSON(res, r.ok ? 200 : 500, r);
    }

    if (mode === "details" || (mode === "auto" && isBookingHotelUrl(target))) {
      const r = await scrapeBookingHotel(target, timeoutMs);
      return sendJSON(res, r.ok ? 200 : 500, r);
    }

    const r = await scrapeGeneric(target, timeoutMs, includeHtml);
    return sendJSON(res, r.ok ? 200 : 500, r);
  } catch (e) {
    return sendJSON(res, 500, { ok: false, error: String(e), url: target });
  }
}

const server = http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url, `http://${req.headers.host}`);

    if (API_KEY) {
      const key = req.headers["x-api-key"];
      if (key !== API_KEY) return unauthorized(res);
    }

    if (url.pathname === "/health" || url.pathname === "/status") {
      return sendJSON(res, 200, { ok: true });
    }

    if (url.pathname === "/scrape") {
      return handleScrape(url.searchParams, res);
    }

    return sendJSON(res, 404, { ok: false, error: "not found" });
  } catch (e) {
    return sendJSON(res, 500, { ok: false, error: String(e) });
  }
});

server.listen(PORT, () => console.log("hotel scraper listening on :" + PORT));
EOF

EXPOSE 10000

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s \
  CMD node -e "fetch('http://127.0.0.1:'+process.env.PORT+'/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"

CMD ["node","/app/server.js"]
