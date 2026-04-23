import type { NextAuthConfig } from "next-auth";

/**
 * Route protection rules.
 * Middleware imports this config (edge-safe subset — no heavy Node.js imports).
 * Full NextAuth config (with Keycloak provider) lives in auth.ts.
 */
export const authConfig: NextAuthConfig = {
  providers: [], // Providers registered in auth.ts; not needed here for route guard

  pages: {
    signIn: "/api/auth/signin",
    error: "/api/auth/error",
  },

  callbacks: {
    authorized({ auth, request: { nextUrl } }) {
      const isLoggedIn = !!auth?.user;

      // Public paths — always accessible
      const publicPaths = ["/api/auth", "/api/health"];
      const isPublic = publicPaths.some((p) => nextUrl.pathname.startsWith(p));
      if (isPublic) return true;

      // All other paths require authentication
      if (isLoggedIn) return true;

      // Redirect unauthenticated users to Keycloak sign-in
      return false; // Middleware will redirect to signIn page
    },
  },
};
