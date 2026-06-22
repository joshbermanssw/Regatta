import { Space_Grotesk, Inter, JetBrains_Mono } from "next/font/google";
import "./globals.css";

const display = Space_Grotesk({
  subsets: ["latin"],
  weight: ["500", "600", "700"],
  variable: "--font-display",
});
const body = Inter({
  subsets: ["latin"],
  weight: ["400", "500", "600"],
  variable: "--font-body",
});
const mono = JetBrains_Mono({
  subsets: ["latin"],
  weight: ["400", "500"],
  variable: "--font-mono",
});

export const metadata = {
  metadataBase: new URL("https://regatta.dev"),
  title: "Regatta — the command deck for AI coding agents",
  description:
    "Hand off the work; a brain races a fleet of agent terminals to a real finish line and shepherds your PRs home.",
  icons: { icon: "/icon.svg" },
  openGraph: {
    title: "Regatta — the command deck for AI coding agents",
    description:
      "Hand it off. Watch it land. A persistent brain races a fleet of agent terminals — each in its own worktree — looping them until the job is done.",
    type: "website",
  },
};

export const viewport = {
  themeColor: "#101116",
};

export default function RootLayout({ children }) {
  return (
    <html lang="en" className={`${display.variable} ${body.variable} ${mono.variable}`}>
      <body>{children}</body>
    </html>
  );
}
