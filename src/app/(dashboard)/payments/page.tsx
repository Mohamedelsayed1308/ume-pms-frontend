'use client';

import { useEffect, useState } from 'react';
import api from '@/lib/api';
import { Plus, Search } from 'lucide-react';

interface Payment {
  id: string;
  payment_reference: string;
  status: string;
  payment_method: string;
  currency: string;
  amount: number;
  payment_date: string;
  supplier?: { name: string };
}

const statusColors: Record<string, string> = {
  pending: 'bg-yellow-900/40 text-yellow-400',
  completed: 'bg-green-900/40 text-green-400',
  cancelled: 'bg-red-900/40 text-red-400',
  failed: 'bg-red-900/40 text-red-400',
};

export default function PaymentsPage() {
  const [payments, setPayments] = useState<Payment[]>([]);
  const [loading, setLoading] = useState(true);
  const [search, setSearch] = useState('');
  const [total, setTotal] = useState(0);

  useEffect(() => {
    api.get('/api/v1/payments?limit=50')
      .then(res => {
        setPayments(res.data.data || res.data);
        setTotal(res.data.total || 0);
      })
      .catch(() => {})
      .finally(() => setLoading(false));
  }, []);

  const filtered = payments.filter(p =>
    p.payment_reference?.toLowerCase().includes(search.toLowerCase()) ||
    p.supplier?.name?.toLowerCase().includes(search.toLowerCase())
  );

  return (
    <div className="p-8">
      <div className="flex items-center justify-between mb-8">
        <div>
          <h1 className="text-2xl font-bold text-white">Payments</h1>
          <p className="text-gray-400 mt-1">{total} payments total</p>
        </div>
        <button className="flex items-center gap-2 bg-blue-600 hover:bg-blue-700 text-white px-4 py-2 rounded-lg text-sm font-medium transition-colors">
          <Plus size={16} />
          New Payment
        </button>
      </div>

      <div className="bg-gray-900 rounded-xl border border-gray-800">
        <div className="p-4 border-b border-gray-800">
          <div className="relative">
            <Search size={16} className="absolute left-3 top-1/2 -translate-y-1/2 text-gray-400" />
            <input
              type="text"
              placeholder="Search payments..."
              value={search}
              onChange={e => setSearch(e.target.value)}
              className="w-full bg-gray-800 border border-gray-700 text-white rounded-lg pl-9 pr-4 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500"
            />
          </div>
        </div>
        <div className="overflow-x-auto">
          <table className="w-full">
            <thead>
              <tr className="border-b border-gray-800">
                <th className="text-left text-xs font-medium text-gray-400 px-4 py-3">Reference</th>
                <th className="text-left text-xs font-medium text-gray-400 px-4 py-3">Supplier</th>
                <th className="text-left text-xs font-medium text-gray-400 px-4 py-3">Method</th>
                <th className="text-left text-xs font-medium text-gray-400 px-4 py-3">Amount</th>
                <th className="text-left text-xs font-medium text-gray-400 px-4 py-3">Status</th>
                <th className="text-left text-xs font-medium text-gray-400 px-4 py-3">Date</th>
              </tr>
            </thead>
            <tbody>
              {loading ? (
                [...Array(5)].map((_, i) => (
                  <tr key={i} className="border-b border-gray-800">
                    {[...Array(6)].map((_, j) => (
                      <td key={j} className="px-4 py-3"><div className="h-4 bg-gray-800 rounded animate-pulse" /></td>
                    ))}
                  </tr>
                ))
              ) : filtered.length === 0 ? (
                <tr><td colSpan={6} className="text-center text-gray-400 py-12">No payments found</td></tr>
              ) : (
                filtered.map(p => (
                  <tr key={p.id} className="border-b border-gray-800 hover:bg-gray-800/50 transition-colors">
                    <td className="px-4 py-3 text-blue-400 text-sm font-mono">{p.payment_reference}</td>
                    <td className="px-4 py-3 text-gray-300 text-sm">{p.supplier?.name || '—'}</td>
                    <td className="px-4 py-3"><span className="text-xs bg-gray-800 text-gray-300 px-2 py-1 rounded-full">{p.payment_method}</span></td>
                    <td className="px-4 py-3 text-white text-sm font-medium">{p.currency} {Number(p.amount || 0).toLocaleString()}</td>
                    <td className="px-4 py-3">
                      <span className={`text-xs px-2 py-1 rounded-full ${statusColors[p.status] || 'bg-gray-700 text-gray-300'}`}>
                        {p.status}
                      </span>
                    </td>
                    <td className="px-4 py-3 text-gray-400 text-sm">
                      {p.payment_date ? new Date(p.payment_date).toLocaleDateString() : '—'}
                    </td>
                  </tr>
                ))
              )}
            </tbody>
          </table>
        </div>
      </div>
    </div>
  );
}
