'use client';

import { useEffect, useState } from 'react';
import api from '@/lib/api';
import { Plus, TrendingUp } from 'lucide-react';

interface ExchangeRate {
  id: string;
  from_currency: string;
  to_currency: string;
  rate: number;
  effective_date: string;
  source: string;
}

export default function ExchangeRatesPage() {
  const [rates, setRates] = useState<ExchangeRate[]>([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    api.get('/api/v1/exchange-rates?limit=50')
      .then(res => setRates(res.data.data || res.data))
      .catch(() => {})
      .finally(() => setLoading(false));
  }, []);

  return (
    <div className="p-8">
      <div className="flex items-center justify-between mb-8">
        <div>
          <h1 className="text-2xl font-bold text-white">Exchange Rates</h1>
          <p className="text-gray-400 mt-1">Currency conversion rates</p>
        </div>
        <button className="flex items-center gap-2 bg-blue-600 hover:bg-blue-700 text-white px-4 py-2 rounded-lg text-sm font-medium transition-colors">
          <Plus size={16} />
          Add Rate
        </button>
      </div>

      <div className="bg-gray-900 rounded-xl border border-gray-800">
        <div className="overflow-x-auto">
          <table className="w-full">
            <thead>
              <tr className="border-b border-gray-800">
                <th className="text-left text-xs font-medium text-gray-400 px-4 py-3">From</th>
                <th className="text-left text-xs font-medium text-gray-400 px-4 py-3">To</th>
                <th className="text-left text-xs font-medium text-gray-400 px-4 py-3">Rate</th>
                <th className="text-left text-xs font-medium text-gray-400 px-4 py-3">Source</th>
                <th className="text-left text-xs font-medium text-gray-400 px-4 py-3">Effective Date</th>
              </tr>
            </thead>
            <tbody>
              {loading ? (
                [...Array(4)].map((_, i) => (
                  <tr key={i} className="border-b border-gray-800">
                    {[...Array(5)].map((_, j) => (
                      <td key={j} className="px-4 py-3"><div className="h-4 bg-gray-800 rounded animate-pulse" /></td>
                    ))}
                  </tr>
                ))
              ) : rates.length === 0 ? (
                <tr>
                  <td colSpan={5} className="py-16 text-center">
                    <TrendingUp size={40} className="text-gray-700 mx-auto mb-3" />
                    <p className="text-gray-400">No exchange rates found</p>
                  </td>
                </tr>
              ) : (
                rates.map(r => (
                  <tr key={r.id} className="border-b border-gray-800 hover:bg-gray-800/50 transition-colors">
                    <td className="px-4 py-3"><span className="text-white font-semibold text-sm bg-blue-900/40 text-blue-400 px-2 py-1 rounded">{r.from_currency}</span></td>
                    <td className="px-4 py-3"><span className="text-white font-semibold text-sm bg-green-900/40 text-green-400 px-2 py-1 rounded">{r.to_currency}</span></td>
                    <td className="px-4 py-3 text-white text-sm font-mono font-bold">{Number(r.rate).toFixed(4)}</td>
                    <td className="px-4 py-3 text-gray-400 text-sm">{r.source || '—'}</td>
                    <td className="px-4 py-3 text-gray-400 text-sm">
                      {r.effective_date ? new Date(r.effective_date).toLocaleDateString() : '—'}
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
