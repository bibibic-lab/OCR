/** @type {import('next').NextConfig} */
const nextConfig = {
  // Output standalone for Docker builds (used in B3-T4)
  // output: 'standalone',

  // Allow images from Keycloak for avatar/profile (future use)
  images: {
    remotePatterns: [
      {
        protocol: "https",
        hostname: "localhost",
      },
      {
        protocol: "https",
        hostname: "keycloak.admin.svc.cluster.local",
      },
    ],
  },
};

export default nextConfig;
