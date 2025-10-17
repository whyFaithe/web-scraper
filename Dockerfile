# ----- Hotel Data Scraper Service -----
FROM mcr.microsoft.com/playwright:v1.47.0-jammy

ENV DEBIAN_FRONTEND=noninteractive
ENV NODE_ENV=production
ENV PORT=10000
ENV PLAYWRIGHT_BROWSERS_PATH=/ms-playwright
ENV PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates && \
    rm -rf /var/lib/apt/lists/*

RUN npm init -y && npm install --omit=dev playwright@1.47.0 cheerio@1.0.0-rc.12

RUN cat > /app/server.js <<'EOF'
const http = require("http");
const { chromium } = require("playwright");
const cheerio = require("cheerio");

const PORT = process.env.PORT || 10000;
const API_KEY = process.env.API_KEY || "";

let browserPromise;
async function getBrowser(){
  if (!browserPromise){
    browserPromise = chromium.launch({
      headless: true,
      args: [
        "--no-sandbox",
        "--disable-setuid-sandbox",
        "--disable-dev-shm-usage",
        "--disable-gpu"
      ]
    });
  }
  return browserPromise;
}

function sendJSON(res, code, obj){
  const body = Buffer.from(JSON.stringify(obj, null, 2));
  res.writeHead(code, {"content-type":"application/json; charset=utf-8","content-length":body.length});
  res.end(body);
}
function unauthorized(res){ return sendJSON(res, 401, {ok:false, error:"unauthorized"}); }
function isPrivateHost(h){ return [/^localhost$/i,/^127\./,/^\[?::1\]?$/, /^10\./,/^192\.168\./,/^172\.(1[6-9]|2\d|3[0-1])\./,/^169\.254\./].some(re=>re.test(h)); }
function isValidHttpUrl(u){ try{ const x=new URL(u); return /^https?:$/.test(x.protocol) && !isPrivateHost(x.hostname); } catch { return false; } }

// Extract structured data from page
function extractHotelData(html, url){
  const $ = cheerio.load(html);
  const data = {
    url,
    title: null,
    address: null,
    phone: null,
    email: null,
    bookingLinks: [],
    structuredData: []
  };

  // Get title
  data.title = $('title').text().trim() || $('h1').first().text().trim();

  // Look for JSON-LD structured data (most reliable)
  $('script[type="application/ld+json"]').each((i, el) => {
    try {
      const json = JSON.parse($(el).html());
      data.structuredData.push(json);
      
      // Extract from structured data
      if (json['@type'] === 'Hotel' || json['@type'] === 'LodgingBusiness'){
        if (json.address) data.address = json.address.streetAddress || JSON.stringify(json.address);
        if (json.telephone) data.phone = json.telephone;
        if (json.email) data.email = json.email;
      }
    } catch {}
  });

  // Look for common booking platform links
  const bookingDomains = ['booking.com', 'expedia.com', 'hotels.com', 'tripadvisor.com', 'airbnb.com', 'vrbo.com', 'agoda.com'];
  $('a[href]').each((i, el) => {
    const href = $(el).attr('href');
    if (href && bookingDomains.some(d => href.includes(d))){
      const fullUrl = new URL(href, url).href;
      if (!data.bookingLinks.includes(fullUrl)){
        data.bookingLinks.push(fullUrl);
      }
    }
  });

  // Fallback: look for address patterns
  if (!data.address){
    const text = $('body').text();
    const addressRegex = /\d+\s+[\w\s]+(?:Street|St|Avenue|Ave|Road|Rd|Boulevard|Blvd|Drive|Dr|Lane|Ln|Way|Court|Ct|Plaza|Parkway|Pkwy)[,\s]+[\w\s]+,\s*[A-Z]{2}\s+\d{5}/gi;
    const match = text.match(addressRegex);
    if (match) data.address = match[0].trim();
  }

  // Fallback: look for phone patterns
  if (!data.phone){
    const text = $('body').text();
    const phoneRegex = /(?:\+?1[-.\s]?)?\(?([0-9]{3})\)?[-.\s]?([0-9]{3})[-.\s]?([0-9]{4})/g;
    const match = text.match(phoneRegex);
    if (match) data.phone = match[0].trim();
  }

  // Look for email
  if (!data.email){
    const text = $('body').text();
    const emailRegex = /[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}/g;
    const match = text.match(emailRegex);
    if (match) data.email = match[0].trim();
  }

  return data;
}

async function handleScrape(qs, res){
  const target = (qs.get("url") || "").trim();
  if (!target || !isValidHttpUrl(target)) return sendJSON(res, 400, {ok:false, error:"invalid url"});

  const timeoutMs = Math.min(30000, Math.max(5000, parseInt(qs.get("timeout") || "15000", 10)));
  const includeHtml = (qs.get("html") || "0") === "1";

  let context, page;
  try{
    const browser = await getBrowser();
    context = await browser.newContext({
      userAgent: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
      viewport: { width: 1920, height: 1080 }
    });

    page = await context.newPage();
    
    await page.goto(target, { 
      waitUntil: "domcontentloaded", 
      timeout: timeoutMs 
    });

    // Wait a bit for dynamic content
    await page.waitForTimeout(2000);

    const html = await page.content();
    const data = extractHotelData(html, target);

    const result = {
      ok: true,
      ...data
    };

    if (includeHtml) result.html = html;

    return sendJSON(res, 200, result);

  } catch (e){
    console.error("scrape error:", e);
    return sendJSON(res, 500, { ok:false, error: String(e), url: target });
  } finally {
    try { if (page) await page.close(); } catch {}
    try { if (context) await context.close(); } catch {}
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

server.listen(PORT, () => console.log("hotel scraper listening on :"+PORT));
EOF

EXPOSE 10000

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s \
  CMD node -e "fetch('http://127.0.0.1:'+process.env.PORT+'/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"

CMD ["node","/app/server.js"]
