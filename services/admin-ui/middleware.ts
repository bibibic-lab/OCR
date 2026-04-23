/**
 * NextAuth v5 middleware for route protection.
 *
 * Exports `auth` from @/auth directly. The `authorized` callback in
 * auth.config.ts defines which routes require authentication.
 *
 * matcher excludes:
 *  - Next.js internals (_next/*)
 *  - Auth API routes (api/auth/*)
 *  - Static assets (favicon.ico, images)
 */
export { auth as middleware } from "@/auth";

export const config = {
  matcher: [
    "/((?!_next/static|_next/image|api/auth|favicon\\.ico|.*\\.(?:png|jpg|jpeg|gif|svg|ico|webp)).*)",
  ],
};
