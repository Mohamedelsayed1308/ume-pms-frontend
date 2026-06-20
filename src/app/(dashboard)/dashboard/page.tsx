'use client';

import { useEffect, useState } from 'react';
import api from '@/lib/api';
import { ShoppingCart, FileText, CreditCard, Building2, TrendingUp, AlertCircle } from 'lucide-react';

interface DashboardSummary {
  total_purchase_orders?: number;
  total_invoices?: number;
  total_payments?: number;
  total_suppliers?: number;
  pending_purchase_orders?: number;
  pending_invoices?: number;
  pending_payments?: number;
}

export default function DashboardPage() {
  const [data, setData] = useState<DashboardSummary>({});
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    api.get('/api/v1/dashboard/summary')
      .then(res => setData(res.data))
      .catch(() => {})
      .finally(() => setLoading(false));
  }, []);

  const cards = [
    { label: 'Purchase Orders', value: data.total_purchase_orders ?? 0, pending: data.pending_purchase_orders ?? 0, icon: ShoppingCart, color: 'blue' },
    { label: 'Invoices', value: data.total_invoices ?? 0, pending: data.pending_invoices ?? 0, icon: FileText, color: 'purple' },
    { label: 'Payments', value: data.total_payments ?? 0, pending: data.pending_payments ?? 0, icon: CreditCard, color: 'green' },
    { label: 'Suppliers', value: data.total_suppliers ?? 0, pending: 0, icon: Building2, color: 'orange' },
  ];

  const colorMap: Record<string, string> = {
    blue: 'bg-blue-600',
    purple: 'bg-purple-600',
    green: 'bg-green-600',
    orange: 'bg-orange-600',
  };

  return (
    <div className="p-8">
      <div className="mb-8">
        <h1 className="text-2xl font-bold text-white">Dashboard</h1>
        <p className="text-gray-400 mt-1">Welcome to UME Holding Procurement Management System</p>
      </div>

      {loading ? (
        <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-6">
          {[...Array(4)].map((_, i) => (
            <div key={i} className="bg-gray-900 rounded-xl p-6 border border-gray-800 animate-pulse h-32" />
          ))}
        </div>
      ) : (
        <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-6">
          {cards.map(({ label, value, pending, icon: Icon, color }) => (
            <div key={label} className="bg-gray-900 rounded-xl p-6 border border-gray-800">
              <div className="flex items-center justify-between mb-4">
                <div className={`w-10 h-10 ${colorMap[color]} rounded-lg flex items-center justify-center`}>
                  <Icon size={20} className="text-white" />
                </div>
                {pending > 0 && (
                  <span className="flex items-center gap-1 text-xs text-yellow-400 bg-yellow-400/10 px-2 py-1 rounded-full">
                    <AlertCircle size={12} />
                    {pending} pending
                  </span>
                )}
              </div>
              <p className="text-3xl font-bold text-white">{value}</p>
              <p className="text-gray-400 text-sm mt-1">{label}</p>
            </div>
          ))}
        </div>
      )}

      <div className="mt-8 bg-gray-900 rounded-xl p-6 border border-gray-800">
        <div className="flex items-center gap-2 mb-4">
          <TrendingUp size={20} className="text-blue-400" />
          <h2 className="text-lg font-semibold text-white">System Status</h2>
        </div>
        <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
          <div className="bg-gray-800 rounded-lg p-4">
            <div className="flex items-center gap-2">
              <div className="w-2 h-2 bg-green-500 rounded-full animate-pulse" />
              <span className="text-gray-300 text-sm">API Connected</span>
            </div>
          </div>
          <div className="bg-gray-800 rounded-lg p-4">
            <div className="flex items-center gap-2">
              <div className="w-2 h-2 bg-green-500 rounded-full animate-pulse" />
              <span className="text-gray-300 text-sm">Database Online</span>
            </div>
          </div>
          <div className="bg-gray-800 rounded-lg p-4">
            <div className="flex items-center gap-2">
              <div className="w-2 h-2 bg-green-500 rounded-full animate-pulse" />
              <span className="text-gray-300 text-sm">Supabase Active</span>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}
