const WAD = 10n ** 18n;

/** A token amount (18 decimals) with a fixed number of decimals, grouped, never in scientific notation. */
export function fmtToken(value: bigint, decimals = 4): string {
  const negative = value < 0n;
  const abs = negative ? -value : value;
  const scale = 10n ** BigInt(decimals);
  const rounded = (abs * scale + WAD / 2n) / WAD;
  const whole = rounded / scale;
  const frac = (rounded % scale).toString().padStart(decimals, "0");
  const grouped = whole.toString().replace(/\B(?=(\d{3})+(?!\d))/g, ",");
  return `${negative && rounded > 0n ? "−" : ""}${grouped}${decimals > 0 ? `.${frac}` : ""}`;
}

/** A signed token amount with an explicit sign. */
export const fmtSigned = (value: bigint, decimals = 4) => (value > 0n ? "+" : "") + fmtToken(value, decimals);

export const fmtInt = (value: bigint | number) => value.toString().replace(/\B(?=(\d{3})+(?!\d))/g, ",");

export const fmtPrice = (price: number) =>
  price >= 1000 ? price.toFixed(1) : price >= 1 ? price.toFixed(4) : price.toPrecision(4);

export const shortAddress = (address: string) => `${address.slice(0, 6)}…${address.slice(-4)}`;

export function fmtDuration(seconds: number): string {
  const s = Math.max(0, Math.round(seconds));
  if (s < 60) return `${s}s`;
  const m = Math.floor(s / 60);
  if (m < 60) return `${m}m ${String(s % 60).padStart(2, "0")}s`;
  const h = Math.floor(m / 60);
  if (h < 48) return `${h}h ${String(m % 60).padStart(2, "0")}m`;
  return `${Math.floor(h / 24)}d ${h % 24}h`;
}

export const fmtAgo = (seconds: number) => (seconds < 5 ? "just now" : `${fmtDuration(seconds)} ago`);

/** Parses a decimal string into 18-decimal units; returns null when it is not a number. */
export function parseToken(input: string): bigint | null {
  const t = input.trim();
  if (!/^\d*\.?\d*$/.test(t) || t === "" || t === ".") return null;
  const [whole, frac = ""] = t.split(".");
  return BigInt(whole || "0") * WAD + BigInt((frac + "0".repeat(18)).slice(0, 18));
}
