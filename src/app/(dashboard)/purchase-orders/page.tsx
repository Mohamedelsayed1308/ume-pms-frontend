'use client';

import { useEffect, useState } from 'react';
import api from '@/lib/api';
import { Plus, Search } from 'lucide-react';

interface PO {
  id: string;
  po_number: string;
  title: string;
  status: string;
  priority: string;
  currency: string;
  total_amount: number;
  order_date: string;
  supplier?: { name: string };
  vessel?: { name: string };
}

const statusColors: Record<string, string> = {
  draft: 'bg-gray-700 text-gray-300',
  submitted: 'bg-yellow-900/40 text-yellow-400',
  approved: 'bg-green-900/40 text-green-400',
  rejected: 'bg-red-900/40 text-red-400',
  cancelled: 'bg-red-900/40 text-red-400',
};

export default function PurchaseOrdersPage() {
  const [orders, setOrders] = useState<PO[]>([]);
  const [loading, setLoading] = useState(true);
  const [search, setSearch] = useState('');
  const [total, setTotal] = useState(0);

  useEffect(() => {
    api.get('/api/v1/purchase-orders?limit=50')
      .then(res => {
        setOrders(res.data.data || res.data);
        setTotal(res.data.total || 0);
      })
      .catch(() => {})
      .finally(() => setLoading(false));
  }, []);

  const filtered = orders.filter(o =>
    o.title?.toLowerCase().includes(search.toLowerCase()) ||
    o.po_number?.toLowerCase().includes(search.toLowerCase())
  );

  return (
    <div className="p-8">
      <div className="flex items-center justify-between mb-8">
        <div>
          <h1 className="text-2xl font-bold text-white">Purchase Orders</h1>
          <p className="text-gray-400 mt-1">{total} orders total</p>
        </div>
        <button className="flex items-center gap-2 bg-blue-600 hover:bg-blue-700 text-white px-4 py-2 rounded-lg text-sm font-medium transition-colors">
          <Plus size={16} />
          New Order
        </button>
      </div>

      <div className="bg-gray-900 rounded-xl border border-gray-800">
        <div className="p-4 border-b border-gray-800">
          <div className="relative">
            <Search size={16} className="absolute left-3 top-1/2 -translate-y-1/2 text-gray-400" />
            <input
              type="text"
              placeholder="Search orders..."
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
                <th className="text-left text-xs font-medium text-gray-400 px-4 py-3">PO Number</th>
                <th className="text-left text-xs font-medium text-gray-400 px-4 py-3">Title</th>
                <th className="text-left text-xs font-medium text-gray-400 px-4 py-3">Supplier</th>
                <th className="text-left text-xs font-medium text-gray-400 px-4 py-3">Vessel</th>
                <th className="text-left text-xs font-medium text-gray-400 px-4 py-3">Amount</th>
                <th className="text-left text-xs font-medium text-gray-400 px-4 py-3">Status</th>
                <th className="text-left text-xs font-medium text-gray-400 px-4 py-3">Date</th>
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
                <tr><td colSpan={7} className="text-center text-gray-400 py-12">No purchase orders found</td></tr>
              ) : (
                filtered.map(o => (
                  <tr key={o.id} className="border-b border-gray-800 hover:bg-gray-800/50 transition-colors">
                    <td className="px-4 py-3 text-blue-400 text-sm font-mono">{o.po_number}</td>
                    <td className="px-4 py-3 text-white text-sm">{o.title}</td>
                    <td className="px-4 py-3 text-gray-400 text-sm">{o.supplier?.name || '—'}</td>
                    <td className="px-4 py-3 text-gray-400 text-sm">{o.vessel?.name || '—'}</td>
                    <td className="px-4 py-3 text-white text-sm font-medium">
                      {o.currency} {Number(o.total_amount || 0).toLocaleString()}
                    </td>
                    <td className="px-4 py-3">
                      <span className={`text-xs px-2 py-1 rounded-full ${statusColors[o.status] || 'bg-gray-700 text-gray-300'}`}>
                        {o.status}
                      </span>
                    </td>
                    <td className="px-4 py-3 text-gray-400 text-sm">
                      {new Date(o.order_date).toLocaleDateString()}
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
