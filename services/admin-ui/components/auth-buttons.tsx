"use client";

import { signIn, signOut } from "next-auth/react";

interface AuthButtonsProps {
  signedIn?: boolean;
  userEmail?: string;
}

/**
 * Client component for sign-in / sign-out buttons.
 * Uses next-auth/react (client-side) because onClick requires interactivity.
 */
export function AuthButtons({ signedIn, userEmail }: AuthButtonsProps) {
  if (signedIn) {
    return (
      <div className="flex items-center gap-3">
        {userEmail && (
          <span className="text-sm text-gray-600 dark:text-gray-300 hidden sm:inline">
            {userEmail}
          </span>
        )}
        <button
          onClick={() => signOut({ callbackUrl: "/" })}
          className="px-4 py-2 text-sm font-medium text-white bg-red-600 hover:bg-red-700 active:bg-red-800 rounded-lg transition-colors focus:outline-none focus:ring-2 focus:ring-red-500 focus:ring-offset-2"
        >
          로그아웃
        </button>
      </div>
    );
  }

  return (
    <button
      onClick={() => signIn("keycloak")}
      className="px-6 py-2.5 text-sm font-medium text-white bg-blue-600 hover:bg-blue-700 active:bg-blue-800 rounded-lg transition-colors focus:outline-none focus:ring-2 focus:ring-blue-500 focus:ring-offset-2"
    >
      Keycloak 로그인
    </button>
  );
}
