import type { Metadata } from "next";
import Header from "@/components/Header";
import Footer from "@/components/Footer";
import "./globals.css";

export const metadata: Metadata = {
  title: {
    default: "AFZ Engineering Inc. | Mechanical Engineering Consultancy â€” Ontario",
    template: "%s | AFZ Engineering Inc.",
  },
  description:
    "AFZ Engineering Inc. is an Ontario mechanical engineering consultancy providing HVAC, heat loss and heat gain, duct design, ventilation, kitchen exhaust and make-up air, plumbing, hydronic, gas piping and mechanical permit services.",
  keywords: [
    "mechanical engineering",
    "Ontario",
    "HVAC",
    "heat loss",
    "heat gain",
    "duct design",
    "ventilation",
    "kitchen exhaust",
    "make-up air",
    "plumbing",
    "hydronic",
    "gas piping",
    "mechanical permits",
  ],
  openGraph: {
    type: "website",
    locale: "en_CA",
    siteName: "AFZ Engineering Inc.",
  },
};

export default function RootLayout({
  children,
}: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="en-CA">
      <body>
        <Header />
        <main id="main" className="site-main">
          {children}
        </main>
        <Footer />
      </body>
    </html>
  );
}