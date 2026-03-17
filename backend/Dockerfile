# Simple production image for the Aether Node backend
FROM node:20-alpine

WORKDIR /app

# Install dependencies first for better caching
COPY package.json package-lock.json* ./
RUN npm ci --omit=dev

# Copy source
COPY . .

ENV NODE_ENV=production
ENV PORT=8080

EXPOSE 8080

CMD ["node", "index.js"]
