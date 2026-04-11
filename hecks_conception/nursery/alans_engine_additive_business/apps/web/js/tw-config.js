/* Tailwind CDN configuration — shared across all pages
   Brand colors map to domain aggregates: DuraLube, MotorKote, Slick 50 */

tailwind.config = {
  darkMode: 'class',
  theme: {
    extend: {
      colors: {
        duralube: { DEFAULT: '#3b82f6', dim: '#2563eb', glow: 'rgba(59,130,246,0.15)' },
        motorkote: { DEFAULT: '#ef4444', dim: '#dc2626', glow: 'rgba(239,68,68,0.15)' },
        slick50: { DEFAULT: '#f59e0b', dim: '#d97706', glow: 'rgba(245,158,11,0.15)' },
        surface: { 0: '#0d0f12', 1: '#161a1f', 2: '#1e2328', 3: '#272d34', 4: '#323940' }
      }
    }
  }
};
