import NextAuth, { type DefaultSession } from "next-auth";
import Keycloak from "next-auth/providers/keycloak";

// Extend NextAuth Session type to include Keycloak tokens
declare module "next-auth" {
  interface Session extends DefaultSession {
    accessToken?: string;
    idToken?: string;
    error?: string;
  }
}

export const { handlers, signIn, signOut, auth } = NextAuth({
  providers: [
    Keycloak({
      clientId: process.env.KEYCLOAK_CLIENT_ID!,
      clientSecret: process.env.KEYCLOAK_CLIENT_SECRET ?? "",
      issuer: process.env.KEYCLOAK_ISSUER!,
    }),
  ],

  callbacks: {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    async jwt({ token, account }: { token: any; account: any }) {
      // Initial sign-in: store tokens from Keycloak
      if (account) {
        return {
          ...token,
          accessToken: account.access_token as string | undefined,
          idToken: account.id_token as string | undefined,
          refreshToken: account.refresh_token as string | undefined,
          expiresAt: account.expires_at as number | undefined,
        };
      }

      const expiresAt = token.expiresAt as number | undefined;

      // Return token as-is if not expired
      if (expiresAt && Date.now() < expiresAt * 1000) {
        return token;
      }

      // Access token expired — flag for re-login (refresh token handling in B3-T4)
      return { ...token, error: "TokenExpired" as const };
    },

    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    async session({ session, token }: { session: any; token: any }) {
      session.accessToken = token.accessToken as string | undefined;
      session.idToken = token.idToken as string | undefined;
      if (token.error) {
        session.error = token.error as string;
      }
      return session;
    },
  },

  // Required for Next.js App Router
  trustHost: true,
});
