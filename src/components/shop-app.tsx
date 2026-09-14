"use client";

import { FormEvent, useEffect, useMemo, useState } from "react";
import { brands, type BrandName, type Product } from "@/lib/catalog";
import {
  hideItem,
  isKept,
  keepItem,
  readBoard,
  visibleFinds,
  writeBoard,
  type Board,
} from "@/lib/board";

function money(value: number) {
  return value ? `$${value}` : "";
}

export function ShopApp() {
  const [board, setBoard] = useState<Board>({ kept: [], hidden: [] });
  const [mode, setMode] = useState<"board" | "find">("board");
  const [brand, setBrand] = useState<BrandName | "all">("all");
  const [draft, setDraft] = useState("");
  const [query, setQuery] = useState("new arrivals");
  const [finds, setFinds] = useState<Product[]>([]);
  const [open, setOpen] = useState<Product | null>(null);
  const [loading, setLoading] = useState(false);

  useEffect(() => {
    setBoard(readBoard());
  }, []);

  useEffect(() => {
    if (mode !== "find") return;
    let ignore = false;
    setLoading(true);
    const params = new URLSearchParams({ q: query });
    if (brand !== "all") params.set("brand", brand);
    void fetch(`/api/shop?${params.toString()}`)
      .then((response) => response.json() as Promise<{ products?: Product[] }>)
      .then((data) => {
        if (!ignore) setFinds(data.products ?? []);
      })
      .catch(() => {
        if (!ignore) setFinds([]);
      })
      .finally(() => {
        if (!ignore) setLoading(false);
      });
    return () => {
      ignore = true;
    };
  }, [mode, query, brand]);

  const items = useMemo(() => {
    if (mode === "board") return board.kept;
    return visibleFinds(board, finds);
  }, [mode, board, finds]);

  function saveBoard(next: Board) {
    setBoard(next);
    writeBoard(next);
  }

  function onSearch(event: FormEvent) {
    event.preventDefault();
    setLoading(true);
    setQuery(draft.trim() || "new arrivals");
    setMode("find");
  }

  function goFind(nextBrand: BrandName | "all") {
    setLoading(true);
    setBrand(nextBrand);
    setMode("find");
  }

  return (
    <div className="min-h-full bg-paper text-ink">
      <header className="sticky top-0 z-20 border-b border-line bg-paper/95 backdrop-blur">
        <div className="mx-auto flex max-w-5xl items-center gap-4 px-4 py-4 md:px-6">
          <button
            type="button"
            className="serif shrink-0 text-[1.6rem] leading-none"
            onClick={() => setMode("board")}
          >
            aisle
          </button>
          <form onSubmit={onSearch} className="flex min-w-0 flex-1 items-center gap-2">
            <input
              value={draft}
              onChange={(event) => setDraft(event.target.value)}
              placeholder="Find pieces to keep"
              className="w-full rounded-full bg-soft px-4 py-2.5 text-sm outline-none placeholder:text-muted"
            />
            <button
              type="submit"
              className="shrink-0 rounded-full bg-ink px-4 py-2.5 text-sm text-paper"
            >
              Find
            </button>
          </form>
        </div>
        {mode === "find" ? (
          <div className="mx-auto flex max-w-5xl gap-2 overflow-x-auto px-4 pb-3 md:px-6">
            <button
              type="button"
              onClick={() => goFind("all")}
              className={`rounded-full px-3 py-1.5 text-sm whitespace-nowrap ${
                brand === "all" ? "bg-ink text-paper" : "text-muted hover:text-ink"
              }`}
            >
              All
            </button>
            {brands.map((name) => (
              <button
                key={name}
                type="button"
                onClick={() => goFind(name)}
                className={`rounded-full px-3 py-1.5 text-sm whitespace-nowrap ${
                  brand === name ? "bg-ink text-paper" : "text-muted hover:text-ink"
                }`}
              >
                {name}
              </button>
            ))}
          </div>
        ) : null}
      </header>

      <main className="mx-auto max-w-5xl px-4 py-8 md:px-6">
        <div className="mb-6">
          <h1 className="text-lg font-medium">
            {mode === "board" ? "Your aisle" : "Find"}
          </h1>
          <p className="mt-1 text-sm text-muted">
            {mode === "board"
              ? board.kept.length
                ? "What you kept. Tap aisle anytime to come back."
                : "Search your stores. Keep what you like. Hide the rest."
              : "Keep it onto your aisle. Hide it so it doesn’t come back."}
          </p>
        </div>

        {mode === "find" && loading ? (
          <p className="py-20 text-center text-sm text-muted">Looking…</p>
        ) : items.length === 0 ? (
          <p className="py-20 text-center text-sm text-muted">
            {mode === "board"
              ? "Nothing kept yet."
              : `Nothing from those stores for “${query}”.`}
          </p>
        ) : (
          <div className="masonry">
            {items.map((item) => (
              <Pin
                key={item.id}
                item={item}
                kept={isKept(board, item)}
                onOpen={() => setOpen(item)}
                onKeep={() => saveBoard(keepItem(board, item))}
                onHide={() => {
                  saveBoard(hideItem(board, item));
                  if (open?.id === item.id) setOpen(null);
                }}
              />
            ))}
          </div>
        )}
      </main>

      {open ? (
        <div
          className="fixed inset-0 z-40 flex items-end justify-center bg-ink/40 p-3 md:items-center"
          onClick={() => setOpen(null)}
        >
          <div
            className="w-full max-w-lg overflow-hidden rounded-3xl bg-card"
            onClick={(event) => event.stopPropagation()}
          >
            <div className="relative aspect-[3/4] bg-soft">
              {/* eslint-disable-next-line @next/next/no-img-element */}
              <img
                src={open.image}
                alt={open.name}
                className="absolute inset-0 h-full w-full object-cover"
              />
            </div>
            <div className="p-5">
              <p className="text-sm text-muted">{open.brand}</p>
              <h2 className="mt-1 text-xl font-medium tracking-tight">{open.name}</h2>
              {open.price ? <p className="mt-1 text-lg">{money(open.price)}</p> : null}
              <div className="mt-6 flex flex-wrap gap-2">
                <a
                  href={open.url}
                  target="_blank"
                  rel="noreferrer"
                  className="rounded-full bg-ink px-4 py-2 text-sm text-paper"
                >
                  Shop at {open.brand}
                </a>
                <button
                  type="button"
                  onClick={() => saveBoard(keepItem(board, open))}
                  className="rounded-full bg-soft px-4 py-2 text-sm"
                >
                  {isKept(board, open) ? "On aisle" : "Keep"}
                </button>
                <button
                  type="button"
                  onClick={() => {
                    saveBoard(hideItem(board, open));
                    setOpen(null);
                  }}
                  className="rounded-full bg-soft px-4 py-2 text-sm"
                >
                  Hide
                </button>
              </div>
            </div>
          </div>
        </div>
      ) : null}
    </div>
  );
}

function Pin({
  item,
  kept,
  onOpen,
  onKeep,
  onHide,
}: {
  item: Product;
  kept: boolean;
  onOpen: () => void;
  onKeep: () => void;
  onHide: () => void;
}) {
  return (
    <article className="group mb-5">
      <div className="relative overflow-hidden rounded-2xl bg-soft">
        <button type="button" onClick={onOpen} className="block w-full">
          {/* eslint-disable-next-line @next/next/no-img-element */}
          <img
            src={item.image}
            alt={item.name}
            className={`w-full object-cover ${item.tall ? "aspect-[3/4]" : "aspect-[4/5]"}`}
          />
        </button>
        <div className="absolute inset-x-3 top-3 flex justify-between">
          <button
            type="button"
            onClick={onKeep}
            className="rounded-full bg-paper px-3 py-1.5 text-xs font-medium shadow-sm"
          >
            {kept ? "On aisle" : "Keep"}
          </button>
          <button
            type="button"
            onClick={onHide}
            className="rounded-full bg-ink px-3 py-1.5 text-xs font-medium text-paper shadow-sm"
          >
            Hide
          </button>
        </div>
        {item.price ? (
          <span className="pointer-events-none absolute bottom-3 left-3 rounded-full bg-paper px-3 py-1.5 text-xs font-medium shadow-sm">
            {money(item.price)}
          </span>
        ) : null}
      </div>
      <button type="button" onClick={onOpen} className="mt-2 block w-full text-left">
        <span className="block text-sm font-medium">{item.brand}</span>
        <span className="block truncate text-sm text-muted">{item.name}</span>
        {item.price ? (
          <span className="mt-0.5 block text-sm">{money(item.price)}</span>
        ) : null}
      </button>
    </article>
  );
}
