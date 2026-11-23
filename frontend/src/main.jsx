import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import 'misans/lib/Normal/MiSansVF.min.css'
import './index.css'
import App from './App.jsx'

createRoot(document.getElementById('root')).render(
  <StrictMode>
    <App />
  </StrictMode>,
)
