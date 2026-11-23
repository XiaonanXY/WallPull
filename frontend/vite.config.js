import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import tailwindcss from '@tailwindcss/vite'

export default defineConfig({
  base: './',
  plugins: [react(), tailwindcss()],
  build: {
    rolldownOptions: {
      output: {
        codeSplitting: {
          groups: [
            { name: 'vendor-motion', test: /node_modules[\\/]motion/ },
            { name: 'vendor-appica', test: /node_modules[\\/](@appica|@base-ui)/ },
            { name: 'vendor-icons', test: /node_modules[\\/]@phosphor-icons/ },
          ],
        },
      },
    },
  },
})
