import { handlers } from "@/auth";

/**
 * NextAuth v5 App Router handler.
 * Exposes GET and POST at /api/auth/* (signin, callback, signout, session, csrf).
 */
export const { GET, POST } = handlers;
