import { readFileSync } from "node:fs";
import { join } from "node:path";
import {
  brands,
  type BrandName,
  type Category,
  type Product,
} from "./catalog";

type ShoppingHit = {
  title?: string;
  source?: string;
  link?: string;
  product_link?: string;
  thumbnail?: string;
  image?: string;
  imageUrl?: string;
  price?: string;
  extracted_price?: number;
  product_id?: string;
};

type OrganicHit = {
  title?: string;
  link?: string;
  snippet?: string;
  thumbnail?: string;
  imageUrl?: string;
};

const brandSites: Record<BrandName, { query: string; hosts: string[] }> = {
  "H&M": { query: "site:hm.com", hosts: ["hm.com"] },
  Mango: { query: "site:shop.mango.com OR site:mango.com", hosts: ["mango.com"] },
  Zara: { query: "site:zara.com", hosts: ["zara.com"] },
  "American Eagle": { query: "site:ae.com", hosts: ["ae.com"] },
  Garage: { query: "site:garageclothing.com", hosts: ["garageclothing.com"] },
  Aritzia: { query: "site:aritzia.com", hosts: ["aritzia.com"] },
};

function budgetFromPrompt(prompt: string) {
  const under = prompt.toLowerCase().match(/under\s*\$?\s*(\d+)/);
  return under ? Number(under[1]) : null;
}

const cache = new Map<string, { at: number; products: Product[] }>();
const CACHE_MS = 30 * 60 * 1000;

function envKey(name: string) {
  const fromProcess = process.env[name]?.trim();
  if (fromProcess) return fromProcess;
  try {
    const text = readFileSync(join(process.cwd(), ".env.local"), "utf8");
    for (const line of text.split(/\r?\n/)) {
      if (!line.startsWith(`${name}=`)) continue;
      return line.slice(name.length + 1).trim().replace(/^['"]|['"]$/g, "");
    }
  } catch {
    return "";
  }
  return "";
}

export function hasLiveKey() {
  return Boolean(envKey("SERPAPI_API_KEY") || envKey("SERPER_API_KEY"));
}

function idFrom(input: string) {
  let hash = 0;
  for (const char of input) hash = (hash * 31 + char.charCodeAt(0)) | 0;
  return `live-${Math.abs(hash).toString(36)}`;
}

function hostOf(url: string) {
  try {
    return new URL(url).hostname.replace(/^www\d*\./, "").replace(/^www\./, "");
  } catch {
    return "";
  }
}

function isStoreUrl(url: string, brand: BrandName) {
  const host = hostOf(url);
  return brandSites[brand].hosts.some(
    (domain) => host === domain || host.endsWith(`.${domain}`),
  );
}

function productScore(url: string) {
  try {
    const path = new URL(url).pathname.toLowerCase();
    const host = hostOf(url);
    if (host.includes("hm.com")) return /productpage/.test(path) ? 2 : 0;
    if (host.includes("zara.com")) return /-p\d{4,}/.test(path) ? 2 : 0;
    if (host.includes("mango.com")) return /\/p\//.test(path) ? 2 : 0;
    if (host.includes("ae.com")) return /\/(?:us|ca)\/en\/p\//.test(path) ? 2 : 0;
    if (host.includes("aritzia.com")) return /\/product\//.test(path) ? 2 : 0;
    if (host.includes("garageclothing.com")) return /\/products\//.test(path) ? 2 : 0;
    return 0;
  } catch {
    return 0;
  }
}

function organicQuery(brand: BrandName, query: string) {
  const q = query.trim();
  if (/^(new arrivals|womens clothing|women'?s clothing)$/i.test(q)) {
    return `${brandSites[brand].query} (dress OR jeans OR shirt OR jacket OR sweater)`;
  }
  return `${brandSites[brand].query} ${q}`;
}

function snippetPrice(text?: string) {
  const match = text?.match(/\$\s*(\d[\d,]*(?:\.\d+)?)/);
  if (!match) return 0;
  const value = Number(match[1].replace(/,/g, ""));
  return Number.isFinite(value) ? Math.round(value) : 0;
}

function isGoogleUrl(url: string) {
  const host = hostOf(url);
  return host === "google.com" || host.endsWith(".google.com");
}

function words(text: string) {
  const skip = new Set(["the", "and", "for", "with", "from", "womens", "women", "ladies"]);
  return new Set(
    text
      .toLowerCase()
      .replace(/[^a-z0-9]+/g, " ")
      .split(" ")
      .filter((word) => word.length > 2 && !skip.has(word)),
  );
}

function titleScore(left: string, right: string) {
  const a = words(left);
  const b = words(right);
  if (!a.size || !b.size) return 0;
  let hit = 0;
  for (const word of a) if (b.has(word)) hit += 1;
  return hit / Math.max(a.size, b.size);
}

function guessCategory(title: string): Category {
  const text = title.toLowerCase();
  if (/jean|denim/.test(text)) return "denim";
  if (/dress|mini dress|slip/.test(text)) return "dresses";
  if (/coat|jacket|blazer|trench|puffer|hoodie|bomber/.test(text)) {
    return "outerwear";
  }
  if (/sweater|cardigan|knit|crew/.test(text)) return "knit";
  if (/skirt|pant|trouser|short|legging|cargo/.test(text)) return "bottoms";
  return "tops";
}

function guessMood(title: string) {
  const text = title.toLowerCase();
  const mood = ["everyday"];
  if (/mini|going out|lace|satin|halter|corset/.test(text)) mood.push("going out", "cute");
  if (/linen|wide|tailor/.test(text)) mood.push("editorial");
  if (/knit|fleece|hoodie/.test(text)) mood.push("cozy");
  return [...new Set(mood)];
}

function parsePrice(hit: ShoppingHit) {
  if (typeof hit.extracted_price === "number" && hit.extracted_price > 0) {
    return Math.round(hit.extracted_price);
  }
  const match = hit.price?.match(/(\d[\d,]*(?:\.\d+)?)/);
  const value = match ? Number(match[1].replace(/,/g, "")) : NaN;
  return Number.isFinite(value) && value > 0 ? Math.round(value) : 0;
}

function bestShopping(title: string, shopping: ShoppingHit[]) {
  let best: ShoppingHit | undefined;
  let bestScore = 0.34;
  for (const hit of shopping) {
    if (parsePrice(hit) <= 0) continue;
    const score = titleScore(title, hit.title || "");
    if (score > bestScore) {
      best = hit;
      bestScore = score;
    }
  }
  return best;
}

function storeProductUrl(hit: ShoppingHit, brand: BrandName) {
  return [hit.link, hit.product_link].find(
    (candidate) =>
      candidate && isStoreUrl(candidate, brand) && !isGoogleUrl(candidate) && productScore(candidate) >= 2,
  );
}

function toProduct(hit: ShoppingHit, brand: BrandName, url: string): Product | null {
  const title = hit.title?.trim();
  const image = hit.thumbnail || hit.image || hit.imageUrl || "";
  if (!title || !url || !image) return null;
  if (!isStoreUrl(url, brand) || isGoogleUrl(url) || productScore(url) < 2) return null;
  const price = parsePrice(hit);
  if (price <= 0) return null;
  return {
    id: idFrom(url),
    name: title,
    brand,
    price,
    category: guessCategory(title),
    tags: title
      .toLowerCase()
      .split(/[^a-z0-9]+/)
      .filter((word) => word.length > 2)
      .slice(0, 8),
    mood: guessMood(title),
    note: "",
    image,
    url,
    tall: /dress|coat|jean|pant/.test(title.toLowerCase()),
  };
}

function fromOrganic(
  row: OrganicHit,
  brand: BrandName,
  shopping: ShoppingHit[],
  maxPrice?: number,
): Product | null {
  const title = row.title?.trim();
  const url = row.link || "";
  if (!title || !isStoreUrl(url, brand) || isGoogleUrl(url)) return null;
  if (productScore(url) < 2) return null;

  const matched = bestShopping(title, shopping);
  const price = matched ? parsePrice(matched) : snippetPrice(row.snippet);
  if (price <= 0) return null;
  if (maxPrice != null && price > maxPrice) return null;

  const image =
    row.thumbnail ||
    row.imageUrl ||
    matched?.thumbnail ||
    matched?.image ||
    matched?.imageUrl ||
    "";

  return {
    id: idFrom(url),
    name: title,
    brand,
    price,
    category: guessCategory(title),
    tags: title
      .toLowerCase()
      .split(/[^a-z0-9]+/)
      .filter((word) => word.length > 2)
      .slice(0, 8),
    mood: guessMood(title),
    note: "",
    image,
    url,
    tall: /dress|coat|jean|pant/.test(title.toLowerCase()),
  };
}

async function serpApiShopping(query: string, maxPrice?: number) {
  const key = envKey("SERPAPI_API_KEY");
  if (!key) return [];
  const url = new URL("https://serpapi.com/search.json");
  url.searchParams.set("engine", "google_shopping");
  url.searchParams.set("q", query);
  url.searchParams.set("hl", "en");
  url.searchParams.set("gl", "us");
  url.searchParams.set("api_key", key);
  if (maxPrice != null) url.searchParams.set("max_price", String(maxPrice));
  const response = await fetch(url.toString());
  if (!response.ok) return [];
  const data = (await response.json()) as { shopping_results?: ShoppingHit[] };
  return data.shopping_results ?? [];
}

async function serperShopping(query: string) {
  const key = envKey("SERPER_API_KEY");
  if (!key) return [];
  const response = await fetch("https://google.serper.dev/shopping", {
    method: "POST",
    headers: {
      "X-API-KEY": key,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({ q: query, gl: "us", hl: "en", num: 40 }),
  });
  if (!response.ok) return [];
  const data = (await response.json()) as { shopping?: ShoppingHit[] };
  return data.shopping ?? [];
}

async function serperOrganic(query: string) {
  const key = envKey("SERPER_API_KEY");
  if (!key) return [];
  const response = await fetch("https://google.serper.dev/search", {
    method: "POST",
    headers: {
      "X-API-KEY": key,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({ q: query, gl: "us", hl: "en", num: 10 }),
  });
  if (!response.ok) return [];
  const data = (await response.json()) as {
    organic?: OrganicHit[];
  };
  return data.organic ?? [];
}

async function serpApiOrganic(query: string) {
  const key = envKey("SERPAPI_API_KEY");
  if (!key) return [];
  const url = new URL("https://serpapi.com/search.json");
  url.searchParams.set("engine", "google");
  url.searchParams.set("q", query);
  url.searchParams.set("hl", "en");
  url.searchParams.set("gl", "us");
  url.searchParams.set("api_key", key);
  const response = await fetch(url.toString());
  if (!response.ok) return [];
  const data = (await response.json()) as {
    organic_results?: OrganicHit[];
  };
  return data.organic_results ?? [];
}

async function searchBrand(
  brand: BrandName,
  query: string,
  maxPrice?: number,
): Promise<Product[]> {
  const qOrganic = organicQuery(brand, query);
  const qShop =
    brand === "Garage" ? `${query} "Garage Clothing"` : `${query} ${brand}`;
  const [organic, shopping] = await Promise.all([
    envKey("SERPAPI_API_KEY") ? serpApiOrganic(qOrganic) : serperOrganic(qOrganic),
    envKey("SERPAPI_API_KEY")
      ? serpApiShopping(qShop, maxPrice)
      : serperShopping(qShop),
  ]);

  const seen = new Set<string>();
  const products: Product[] = [];

  for (const hit of shopping) {
    if (maxPrice != null && parsePrice(hit) > maxPrice) continue;
    const url = storeProductUrl(hit, brand);
    if (!url) continue;
    const item = toProduct(hit, brand, url);
    if (!item || seen.has(item.id)) continue;
    seen.add(item.id);
    products.push(item);
  }

  for (const row of organic) {
    const item = fromOrganic(row, brand, shopping, maxPrice);
    if (!item || seen.has(item.id) || !item.image) continue;
    seen.add(item.id);
    products.push(item);
  }

  return products.filter((item) => item.price > 0 && productScore(item.url) >= 2);
}

export async function searchLive(options: {
  query: string;
  brand?: BrandName;
  maxPrice?: number;
  limit?: number;
}): Promise<{ live: boolean; products: Product[] }> {
  const query = options.query.trim() || "womens clothing";
  const budget = options.maxPrice ?? budgetFromPrompt(query);
  const limit = options.limit ?? 48;
  const cacheKey = JSON.stringify({
    query,
    v: 10,
    brand: options.brand ?? "all",
    budget,
    live: hasLiveKey(),
  });
  const cached = cache.get(cacheKey);
  if (cached && Date.now() - cached.at < CACHE_MS) {
    return { live: hasLiveKey(), products: cached.products.slice(0, limit) };
  }

  if (!hasLiveKey()) {
    return { live: false, products: [] };
  }

  let products: Product[] = [];
  if (options.brand) {
    products = await searchBrand(options.brand, query, budget ?? undefined);
  } else {
    const groups = await Promise.all(
      brands.map((name) => searchBrand(name, query, budget ?? undefined).then((rows) => rows.slice(0, 8))),
    );
    const mixed: Product[] = [];
    const max = Math.max(0, ...groups.map((group) => group.length));
    for (let index = 0; index < max; index += 1) {
      for (const group of groups) {
        const row = group[index];
        if (row) mixed.push(row);
      }
    }
    products = mixed;
  }

  cache.set(cacheKey, { at: Date.now(), products });
  return { live: true, products: products.slice(0, limit) };
}

export function liveNewArrivalsQuery(brand?: BrandName) {
  return brand
    ? `${brandSites[brand].query} womens new arrivals`
    : "womens new arrivals clothing";
}
