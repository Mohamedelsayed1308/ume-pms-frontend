'use client';

import { useEffect, useState } from 'react';
import api from '@/lib/api';
import { Plus, Search, Ship } from 'lucide-react';

interface Vessel {
  id: string;
  name: string;
  imo_number: string;
  vessel_type: string;
  flag: string;
  gross_tonnage: number;
  year_built: number;
  is_active: boolean;
}

export default function VesselsPage() {
  const [vessels, setVessels] = useState<Vessel[]>([]);
  const [loading, setLoading] = useState(true);
  const [search, setSearch] = useState('');
  const [total, setTotal] = useState(0);

  useEffect(() => {
    api.get('/api/v1/vessels?limit=50')
      .then(res => {
        setVessels(res.data.data || res.data);
        setTotal(res.data.total || 0);
      })
      .catch(() => {})
      .finally(() => setLoading(false));
  }, []);

  const filtered = vessels.filter(v =>
    v.name?.toLowerCase().includes(search.toLowerCase()) ||
    v.imo_number?.toLowerCase().includes(search.toLowerCase())
  );

  return (
    <div className="p-8">
      <div className="flex items-center justify-between mb-8">
        <div>
          <h1 className="text-2xl font-bold text-white">Vessels</h1>
          <p className="text-gray-400 mt-1">{total} vessels in fleet</p>
        </div>
        <button className="flex items-center gap-2 bg-blue-600 hover:bg-blue-700 text-white px-4 py-2 rounded-lg text-sm font-medium transition-colors">
          <Plus size={16} />
          Add Vessel
        </button>
      </div>

      <div className="bg-gray-900 rounded-xl border border-gray-800">
        <div className="p-4 border-b border-gray-800">
          <div className="relative">
            <Search size={16} className="absolute left-3 top-1/2 -translate-y-1/2 text-gray-400" />
            <input
              type="text"
              placeholder="Search vessels..."
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
                <th className="text-left text-xs font-medium text-gray-400 px-4 py-3">Name</th>
                <th className="text-left text-xs font-medium text-gray-400 px-4 py-3">IMO Number</th>
                <th className="text-left text-xs font-medium text-gray-400 px-4 py-3">Type</th>
                <th className="text-left text-xs font-medium text-gray-400 px-4 py-3">Flag</th>
                <th className="text-left text-xs font-medium text-gray-400 px-4 py-3">Gross Tonnage</th>
                <th className="text-left text-xs font-medium text-gray-400 px-4 py-3">Year Built</th>
                <th className="text-left text-xs font-medium text-gray-400 px-4 py-3">Status</th>
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
                <tr>
                  <td colSpan={7} className="py-16 text-center">
                    <Ship size={40} className="text-gray-700 mx-auto mb-3" />
                    <p className="text-gray-400">No vessels found</p>
                  </td>
                </tr>
              ) : (
                filtered.map(v => (
                  <tr key={v.id} className="border-b border-gray-800 hover:bg-gray-800/50 transition-colors">
                    <td className="px-4 py-3 text-white text-sm font-medium">{v.name}</td>
                    <td className="px-4 py-3 text-blue-400 text-sm font-mono">{v.imo_number}</td>
                    <td className="px-4 py-3"><span className="text-xs bg-gray-800 text-gray-300 px-2 py-1 rounded-full">{v.vessel_type}</span></td>
                    <td className="px-4 py-3 text-gray-400 text-sm">{v.flag}</td>
                    <td className="px-4 py-3 text-gray-400 text-sm">{v.gross_tonnage?.toLocaleString()} GT</td>
                    <td className="px-4 py-3 text-gray-400 text-sm">{v.year_built}</td>
                    <td className="px-4 py-3">
                      <span className={`text-xs px-2 py-1 rounded-full ${v.is_active ? 'bg-green-900/40 text-green-400' : 'bg-red-900/40 text-red-400'}`}>
                        {v.is_active ? 'Active' : 'Inactive'}
                      </span>
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
