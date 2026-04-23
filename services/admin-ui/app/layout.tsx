import type { Metadata } from "next";
import { SessionProvider } from "next-auth/react";
import "./globals.css";

export const metadata: Metadata = {
  title: "OCR Admin",
  description: "OCR 문서 처리 관리 UI",
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="ko">
      <body>
        {/*
          SessionProvider makes session available to client components.
          Server components use auth() from @/auth directly (no provider needed).
        */}
        <SessionProvider>{children}</SessionProvider>
      </body>
    </html>
  );
}
