// Dependency-free i18n: two locales with flat key dicts and {var}
// interpolation. The fa dict is typed against en's keys, so a missing
// translation is a compile error. Locale persists in localStorage and drives
// <html lang>/<html dir> — Tailwind logical properties (ms-/me-/text-start)
// handle the actual mirroring.
import {
  createContext, useContext, useEffect, useMemo, useState,
  type ReactNode,
} from "react";
import { en } from "./en";
import { fa } from "./fa";

export type Locale = "en" | "fa";
export type MsgKey = keyof typeof en;

const DICTS: Record<Locale, Record<MsgKey, string>> = { en, fa };
const STORAGE_KEY = "deploypal.locale";

export type TFunc = (key: MsgKey | (string & {}), vars?: Record<string, string | number>) => string;

interface I18n {
  locale: Locale;
  dir: "ltr" | "rtl";
  t: TFunc;
  setLocale: (locale: Locale) => void;
  /** BCP-47 tag for Intl formatters (toLocaleTimeString etc.) */
  intl: string | undefined;
}

const I18nContext = createContext<I18n>({
  locale: "en", dir: "ltr", t: (k) => String(k), setLocale: () => {}, intl: undefined,
});

export function LocaleProvider({ children }: { children: ReactNode }) {
  const [locale, setLocale] = useState<Locale>(() => {
    const stored = localStorage.getItem(STORAGE_KEY);
    return stored === "fa" ? "fa" : "en";
  });
  const dir = locale === "fa" ? "rtl" : "ltr";

  useEffect(() => {
    document.documentElement.lang = locale;
    document.documentElement.dir = dir;
    localStorage.setItem(STORAGE_KEY, locale);
  }, [locale, dir]);

  const value = useMemo<I18n>(() => {
    const dict = DICTS[locale];
    const t: TFunc = (key, vars) => {
      let msg = dict[key as MsgKey] ?? en[key as MsgKey] ?? String(key);
      if (vars) {
        for (const [k, v] of Object.entries(vars)) {
          msg = msg.replace(`{${k}}`, String(v));
        }
      }
      return msg;
    };
    return {
      locale, dir, t, setLocale,
      intl: locale === "fa" ? "fa-IR" : undefined,
    };
  }, [locale, dir]);

  return <I18nContext.Provider value={value}>{children}</I18nContext.Provider>;
}

export const useI18n = () => useContext(I18nContext);
