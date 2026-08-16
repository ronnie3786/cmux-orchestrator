import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

export default defineConfig({
  plugins: [react()],
  base: "/harness-web/",
  build: {
    outDir: "../../cmux_harness/static/harness-web",
    emptyOutDir: true
  }
});
