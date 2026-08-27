FROM oven/bun:1

WORKDIR /app
COPY package.json ./
COPY server.ts ./
COPY public ./public

EXPOSE 3000
CMD ["bun", "run", "server.ts"]
