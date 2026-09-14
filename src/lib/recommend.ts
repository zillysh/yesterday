import { catalog, productsByIds, type Product } from "./catalog";

export type Taste = {
  saved: string[];
  refs: string[];
};

function tokens(text: string) {
  return text
    .toLowerCase()
    .replace(/[^a-z0-9\s$]/g, " ")
    .split(/\s+/)
    .filter((word) => word.length > 2);
}

function haystack(item: Product) {
  return `${item.name} ${item.brand} ${item.category} ${item.tags.join(" ")} ${item.mood.join(" ")} ${item.note}`;
}

function tasteSignals(taste: Taste) {
  const ids = [...new Set([...taste.refs, ...taste.saved])];
  const items = productsByIds(ids);
  const moods = new Map<string, number>();
  const tags = new Map<string, number>();
  const brands = new Map<string, number>();
  const categories = new Map<string, number>();

  for (const row of items) {
    const weight = taste.refs.includes(row.id) ? 3 : 2;
    brands.set(row.brand, (brands.get(row.brand) ?? 0) + weight);
    categories.set(row.category, (categories.get(row.category) ?? 0) + weight);
    for (const mood of row.mood) {
      moods.set(mood, (moods.get(mood) ?? 0) + weight);
    }
    for (const tag of row.tags) {
      tags.set(tag, (tags.get(tag) ?? 0) + weight);
    }
  }

  return { moods, tags, brands, categories, seeded: items.length > 0 };
}

export function scoreAgainstTaste(item: Product, taste: Taste) {
  const { moods, tags, brands, categories, seeded } = tasteSignals(taste);
  if (!seeded) return 1;
  let score = 0.4;
  score += (brands.get(item.brand) ?? 0) * 0.9;
  score += (categories.get(item.category) ?? 0) * 0.7;
  for (const mood of item.mood) score += (moods.get(mood) ?? 0) * 1.1;
  for (const tag of item.tags) score += (tags.get(tag) ?? 0) * 0.7;
  if (taste.saved.includes(item.id) || taste.refs.includes(item.id)) {
    score *= 0.15;
  }
  return score;
}

export function forYouFeed(taste: Taste, extraIds: string[] = []) {
  const extra = productsByIds(extraIds);
  const ranked = [...catalog]
    .map((row) => ({ item: row, score: scoreAgainstTaste(row, taste) }))
    .sort((a, b) => b.score - a.score)
    .map((row) => row.item);

  const seen = new Set<string>();
  const out: Product[] = [];
  for (const row of [...extra, ...ranked]) {
    if (seen.has(row.id)) continue;
    seen.add(row.id);
    out.push(row);
  }
  return out;
}

export function relatedTo(seedId: string, limit = 8) {
  const seed = catalog.find((row) => row.id === seedId);
  if (!seed) return catalog.slice(0, limit);

  const scored = catalog
    .filter((row) => row.id !== seedId)
    .map((row) => {
      let score = 0;
      if (row.category === seed.category) score += 4;
      if (row.brand !== seed.brand) score += 1.5;
      if (row.brand === seed.brand) score += 1;
      for (const mood of row.mood) {
        if (seed.mood.includes(mood)) score += 3;
      }
      for (const tag of row.tags) {
        if (seed.tags.includes(tag)) score += 3.5;
      }
      const priceGap = Math.abs(row.price - seed.price);
      if (priceGap < 25) score += 1;
      if (seed.price > 100 && row.price < seed.price * 0.6) score += 2;
      return { item: row, score };
    })
    .sort((a, b) => b.score - a.score);

  return scored.slice(0, limit).map((row) => row.item);
}

export function sectionPicks(
  moods: readonly string[],
  taste: Taste,
  limit = 5,
  options?: { maxPrice?: number; category?: Exclude<Product["category"], never> },
) {
  return [...catalog]
    .map((row) => {
      let score = row.mood.filter((mood) => moods.includes(mood)).length * 4;
      if (options?.maxPrice != null) {
        score += row.price <= options.maxPrice ? 6 : -8;
      }
      if (options?.category) {
        score += row.category === options.category ? 8 : -4;
      }
      score += scoreAgainstTaste(row, taste) * 0.3;
      return { item: row, score };
    })
    .filter((row) => row.score > 0)
    .sort((a, b) => b.score - a.score)
    .slice(0, limit)
    .map((row) => row.item);
}

export function budgetFromPrompt(prompt: string) {
  const lower = prompt.toLowerCase();
  const under = lower.match(/under\s*\$?\s*(\d+)/);
  if (under) return Number(under[1]);
  if (/cheap|budget|mall/.test(lower)) return 40;
  if (/too exp|expensive|dupes?|cheaper/.test(lower)) return 80;
  return null;
}

export function searchCatalog(prompt: string, limit = 24): Product[] {
  const words = tokens(prompt);
  const budget = budgetFromPrompt(prompt);
  if (!words.length && budget == null) return [];

  const scored = catalog
    .map((row) => {
      let score = 0;
      const hay = tokens(haystack(row));
      for (const word of words) {
        if (hay.includes(word)) score += 2;
        if (row.brand.toLowerCase().includes(word)) score += 4;
        if (row.category.includes(word)) score += 3;
        if (row.tags.some((tag) => tag.includes(word) || word.includes(tag))) {
          score += 3;
        }
        if (row.mood.some((mood) => mood.includes(word) || word.includes(mood))) {
          score += 3;
        }
      }
      if (budget != null) score += row.price <= budget ? 5 : -8;
      return { item: row, score };
    })
    .filter((row) => row.score > 0)
    .sort((a, b) => b.score - a.score);

  return scored.slice(0, limit).map((row) => row.item);
}

export function recommendFromPrompt(prompt: string, limit = 5): Product[] {
  const picks = searchCatalog(prompt, limit);
  if (picks.length >= 3) return picks;

  const fallback = [...catalog].sort((a, b) => a.price - b.price);
  const merged = [...picks];
  for (const row of fallback) {
    if (!merged.some((existing) => existing.id === row.id)) merged.push(row);
    if (merged.length >= limit) break;
  }
  return merged;
}

export function localStylistReply(prompt: string, picks: Product[]) {
  const names = picks
    .map((row) => `${row.name} (${row.brand}, $${row.price})`)
    .join(", ");
  return `Pulled from your stores for “${prompt.trim()}”: ${names}. Save what you like — or mark a reference and I’ll hunt cousins across brands.`;
}

export function serializeProduct(row: Product) {
  return {
    id: row.id,
    name: row.name,
    brand: row.brand,
    price: row.price,
    note: row.note,
    image: row.image,
    url: row.url,
    category: row.category,
    mood: row.mood,
    tall: row.tall ?? false,
  };
}

export function serializePicks(ids: string[]) {
  return productsByIds(ids).map(serializeProduct);
}
