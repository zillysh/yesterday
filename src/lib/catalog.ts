export type Category = "tops" | "bottoms" | "dresses" | "outerwear" | "knit" | "denim";

export type BrandName =
  | "H&M"
  | "Mango"
  | "Zara"
  | "American Eagle"
  | "Garage"
  | "Aritzia";

export type Product = {
  id: string;
  name: string;
  brand: BrandName;
  price: number;
  category: Category;
  tags: string[];
  mood: string[];
  note: string;
  image: string;
  url: string;
  tall?: boolean;
};

export const brands: BrandName[] = [
  "H&M",
  "Mango",
  "Zara",
  "American Eagle",
  "Garage",
  "Aritzia",
];

export const catalog: Product[] = [];

export function productsByIds(ids: string[]) {
  return ids
    .map((id) => catalog.find((row) => row.id === id))
    .filter((row): row is Product => Boolean(row));
}

export const catalogDigest = "";
