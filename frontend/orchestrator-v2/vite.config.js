import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

export default defineConfig({
  plugins: [react()],
  base: "/orchestrator-v2/",
  build: {
    outDir: "../../cmux_harness/static/orchestrator-v2",
    emptyOutDir: true
  },
  test: {
    globals: true,
    environment: "jsdom",
    setupFiles: ["./src/testSetup.js"]
  }
});
