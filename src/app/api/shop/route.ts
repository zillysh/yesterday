import { type BrandName } from "@/lib/catalog";
import { liveNewArrivalsQuery, searchLive } from "@/lib/live";

export const maxDuration = 30;

export async function GET(request: Request) {
  const url = new URL(request.url);
  const query = url.searchParams.get("q") ?? liveNewArrivalsQuery();
  const brandParam = url.searchParams.get("brand");
  const brand = brandParam && brandParam !== "all" ? (brandParam as BrandName) : undefined;
  const maxRaw = url.searchParams.get("maxPrice");
  const maxPrice = maxRaw ? Number(maxRaw) : undefined;
  const result = await searchLive({
    query,
    brand,
    maxPrice: Number.isFinite(maxPrice) ? maxPrice : undefined,
    limit: 48,
  });
  return Response.json(result);
}
