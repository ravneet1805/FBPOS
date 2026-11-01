export type Product = { id: string; name: string; price_rupees: number; active: boolean };
export type Sale = { id: string; idempotency_key:string; product_id:string; product_name:string; original_unit_price:number; quantity:number; gross_amount:number; discount_amount:number; discount_type:'none'|'per_unit'|'transaction'|'final_total'; final_amount:number; payment_method:'cash'|'upi'; status:'complete'|'void'; created_at:string };
export const inr = (n:number) => new Intl.NumberFormat('en-IN',{style:'currency',currency:'INR',maximumFractionDigits:0}).format(n);
export const dayKey = (iso:string) => new Intl.DateTimeFormat('en-CA',{timeZone:'Asia/Kolkata',year:'numeric',month:'2-digit',day:'2-digit'}).format(new Date(iso));
