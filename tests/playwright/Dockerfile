# Optional: build your own inspector image instead of installing at Job start.
FROM mcr.microsoft.com/playwright:v1.47.2-noble
WORKDIR /work
COPY package.json playwright.config.js rbac.spec.js ./
RUN npm install --no-fund --no-audit
ENV CI=true
CMD ["npx", "playwright", "test", "--reporter=list"]
