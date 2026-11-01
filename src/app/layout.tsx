import type { Metadata, Viewport } from 'next';
import './globals.css';
export const metadata: Metadata = { title: 'FOR BROTHERS', description: 'Fast shared exhibition sales', manifest: '/manifest.webmanifest', icons: { apple: '/apple-touch-icon.png' }, appleWebApp: { capable: true, statusBarStyle: 'default', title: 'FOR BROTHERS' } };
export const viewport: Viewport = { themeColor: '#f6f7f5', width: 'device-width', initialScale: 1, maximumScale: 1 };
export default function RootLayout({children}:{children:React.ReactNode}) { return <html lang="en"><body>{children}</body></html>; }
