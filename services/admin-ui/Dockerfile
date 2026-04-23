# ── Stage 1: Builder ─────────────────────────────────────────────────────────
FROM --platform=linux/amd64 node:20-alpine AS builder
WORKDIR /app

# Install deps first (cache layer)
COPY package.json package-lock.json ./
RUN --mount=type=cache,target=/root/.npm \
    npm ci --no-audit --no-fund

# Copy source and build
COPY . .

# Next.js standalone build (output: 'standalone' in next.config.mjs)
RUN npm run build

# ── Stage 2: Runtime ──────────────────────────────────────────────────────────
FROM --platform=linux/amd64 node:20-alpine AS runtime
WORKDIR /app

# Non-root user (GID/UID 1001 — alpine node:20 reserves 1000 for node user)
RUN addgroup -g 1001 nextjs && adduser -D -u 1001 -G nextjs nextjs

# Copy standalone output from builder
COPY --from=builder --chown=1001:1001 /app/.next/standalone ./
COPY --from=builder --chown=1001:1001 /app/.next/static ./.next/static
# public/ 디렉토리가 없는 경우도 처리 (Next.js standalone은 없어도 동작)
# COPY --from=builder --chown=1001:1001 /app/public ./public

USER 1001:1001

EXPOSE 3000

ENV NODE_ENV=production \
    PORT=3000 \
    HOSTNAME=0.0.0.0

CMD ["node", "server.js"]
