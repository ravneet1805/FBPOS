import { createClient } from '@supabase/supabase-js';
export const admin = createClient(process.env.NEXT_PUBLIC_SUPABASE_URL || 'https://example.supabase.co', process.env.SUPABASE_SERVICE_ROLE_KEY || 'not-configured', {auth:{persistSession:false,autoRefreshToken:false}});
