import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";

export default defineConfig({
  plugins: [react(), tailwindcss()],
  server: {
    // Dev mode: proxy API + WebSockets to a locally running orchestrator.
    proxy: {
      "/api": { target: "http://127.0.0.1:8443", ws: true },
    },
  },
  build: { outDir: "dist" },
});
