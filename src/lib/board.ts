import type { Product } from "./catalog";

export type Board = {
  kept: Product[];
  hidden: string[];
};

const KEY = "aisle-board";

const empty: Board = { kept: [], hidden: [] };

function keysOf(item: Product) {
  return [item.id, item.url];
}

export function readBoard(): Board {
  try {
    const parsed = JSON.parse(localStorage.getItem(KEY) ?? "") as Partial<Board>;
    return {
      kept: Array.isArray(parsed.kept) ? parsed.kept : [],
      hidden: Array.isArray(parsed.hidden) ? parsed.hidden : [],
    };
  } catch {
    return empty;
  }
}

export function writeBoard(board: Board) {
  localStorage.setItem(KEY, JSON.stringify(board));
}

export function isHidden(board: Board, item: Product) {
  const keys = new Set(board.hidden);
  return keysOf(item).some((key) => keys.has(key));
}

export function isKept(board: Board, item: Product) {
  return board.kept.some((row) => row.id === item.id || row.url === item.url);
}

export function keepItem(board: Board, item: Product): Board {
  const hidden = board.hidden.filter((key) => !keysOf(item).includes(key));
  const kept = [
    item,
    ...board.kept.filter((row) => row.id !== item.id && row.url !== item.url),
  ];
  return { kept, hidden };
}

export function hideItem(board: Board, item: Product): Board {
  const kept = board.kept.filter((row) => row.id !== item.id && row.url !== item.url);
  const extra = keysOf(item).filter((key) => !board.hidden.includes(key));
  return { kept, hidden: [...board.hidden, ...extra] };
}

export function visibleFinds(board: Board, items: Product[]) {
  return items.filter((item) => !isHidden(board, item));
}
