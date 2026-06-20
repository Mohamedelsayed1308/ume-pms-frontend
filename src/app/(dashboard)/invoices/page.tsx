'use client';

import { useEffect, useState } from 'react';
import api from '@/lib/api';
import { Plus, Search } from 'lucide-react';

interface Invoice {
  id: string;
  invoice_number: string;
  status: string;
  currency: string;
  total_amount: number;
  paid_amount: number;
  remaining_amount: number;
  invoice_date: string;
  due_date: string;
  supplier?: { name: string };
}

const statusColors: Record<string, string> = {
  draft: 'bg-gray-700 text-gray-300',
  submitted: 'bg-yellow-900/40 text-yellow-400',
  approved: 'bg-blue-900/40 text-blue-400',
  partially_paid: 'bg-orange-900/40 text-orange-400',
  paid: 'bg-green-900/40 text-green-400',
  rejected: 'bg-red-900/40 text-red-400',
  cancelled: 'bg-red-900/40 text-red-400',
};

export default function InvoicesPage() {
  const [invoices, setInvoices] = useState<Invoice[]>([]);
  const [loading, setLoading] = useState(true);
  const [search, setSearch] = useState('');
  const [total, setTotal] = useState(0);

  useEffect(() => {
    api.get('/api/v1/invoices?limit=50')
      .then(res => {
        setInvoices(res.data.data || res.data);
        setTotal(res.data.total || 0);
      })
      .catch(() => {})
      .finally(() => setLoading(false));
  }, []);

  const filtered = invoices.filter(i =>
    i.invoice_number?.toLowerCase().includes(search.toLowerCase()) ||
    i.supplier?.name?.toLowerCase().includes(search.toLowerCase())
  );

  return (
    <div className="p-8">
      <div className="flex items-center justify-between mb-8">
        <div>
          <h1 className="text-2xl font-bold text-white">Invoices</h1>
          <p className="text-gray-400 mt-1">{total} invoices total</p>
        </div>
        <button className="flex items-center gap-2 bg-blue-600 hover:bg-blue-700 text-white px-4 py-2 rounded-lg text-sm font-medium transition-colors">
          <Plus size={16} />
          New Invoice
        </button>
      </div>

      <div className="bg-gray-900 rounded-xl border border-gray-800">
        <div className="p-4 border-b border-gray-800">
          <div className="relative">
            <Search size={16} className="absolute left-3 top-1/2 -translate-y-1/2 text-gray-400" />
            <input
              type="text"
              placeholder="Search invoices..."
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
                <th className="text-left text-xs font-medium text-gray-400 px-4 py-3">Invoice #</th>
                <th className="text-left text-xs font-medium text-gray-400 px-4 py-3">Supplier</th>
                <th className="text-left text-xs font-medium text-gray-400 px-4 py-3">Total</th>
                <th className="text-left text-xs font-medium text-gray-400 px-4 py-3">Paid</th>
                <th className="text-left text-xs font-medium text-gray-400 px-4 py-3">Remaining</th>
                <th className="text-left text-xs font-medium text-gray-400 px-4 py-3">Status</th>
                <th className="text-left text-xs font-medium text-gray-400 px-4 py-3">Due Date</th>
              </tr>
            </thead>
            <tbody>
              {loading ? (
                [...Array(5)].map((_, i) => (
                  <tr key={i} className="border-b border-gray-800">
                    {[...Array(7)].map((_, j) => (
                      <td key={j} className="px-4 py-3"><div className="h-4 bg-gray-800 rounded animate-pulse" /></td>
                    ))}
                  </tr>
                ))
              ) : filtered.length === 0 ? (
                <tr><td colSpan={7} className="text-center text-gray-400 py-12">No invoices found</td></tr>
              ) : (
                filtered.map(inv => (
                  <tr key={inv.id} className="border-b border-gray-800 hover:bg-gray-800/50 transition-colors">
                    <td className="px-4 py-3 text-blue-400 text-sm font-mono">{inv.invoice_number}</td>
                    <td className="px-4 py-3 text-gray-300 text-sm">{inv.supplier?.name || '—'}</td>
                    <td className="px-4 py-3 text-white text-sm">{inv.currency} {Number(inv.total_amount || 0).toLocaleString()}</td>
                    <td className="px-4 py-3 text-green-400 text-sm">{Number(inv.paid_amount || 0).toLocaleString()}</td>
                    <td className="px-4 py-3 text-orange-400 text-sm">{Number(inv.remaining_amount || 0).toLocaleString()}</td>
                    <td className="px-4 py-3">
                      <span className={`text-xs px-2 py-1 rounded-full ${statusColors[inv.status] || 'bg-gray-700 text-gray-300'}`}>
                        {inv.status}
                      </span>
                    </td>
                    <td className="px-4 py-3 text-gray-400 text-sm">
                      {inv.due_date ? new Date(inv.due_date).toLocaleDateString() : '—'}
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
