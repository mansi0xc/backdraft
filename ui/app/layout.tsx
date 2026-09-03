import type { Metadata } from "next";
import { Newsreader, Inter } from "next/font/google";
import "./globals.css";
import SmoothScroll from "@/components/SmoothScroll";

// Newsreader: a genuine broadsheet/news serif with optical sizing and a strong
// italic. The chosen design reference is an editorial gothic broadside, so a
// news-class serif is the brand voice, not a decorative flourish.
const serif = Newsreader({
  subsets: ["latin"],
  weight: ["400", "500"],
  style: ["normal", "italic"],
  variable: "--font-serif",
  display: "swap",
});

const sans = Inter({
  subsets: ["latin"],
  weight: ["400", "500"],
  variable: "--font-sans",
  display: "swap",
});

export const metadata: Metadata = {
  title: "Backdraft. The pool is sitting on money.",
  description:
    "A Uniswap v4 hook that prices the mispricing a swap leaves behind, and returns the captured value to the traders who created it and the LPs who funded it. UHI10, HK-UHI10-1088.",
};

export default function RootLayout({
  children,
}: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="en" className={`${serif.variable} ${sans.variable}`}>
      <body className="grain">
        <SmoothScroll>{children}</SmoothScroll>
      </body>
    </html>
  );
}
