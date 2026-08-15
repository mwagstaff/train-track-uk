# syntax=docker/dockerfile:1
ARG NODE_VERSION=22.2.0
FROM node:${NODE_VERSION}-slim AS base
WORKDIR /app
ENV NODE_ENV=production

FROM base AS build
COPY package.json package-lock.json ./
RUN npm ci
COPY . .

FROM base
COPY --from=build /app /app
EXPOSE 3001
CMD ["npm", "start"]
