'use client';

import { useEffect, useState } from 'react';
import api from '@/lib/api';
import { Plus, Search, Building2 } from 'lucide-react';

interface BankAccount {
  id: string;
  account_name: string;
  account_number: string;
  bank_name: string;
  currency: string;
  swift_code: string;
  iban: string;
  is_active: boolean;
}

export default function BankAccountsPage() {
  const [accounts, setAccounts] = useState<BankAccount[]>([]);
  const [loading, setLoading] = useState(true);
  const [search, setSearch] = useState('');

  useEffect(() => {
    api.get('/api/v1/bank-accounts?limit=50')
      .then(res => setAccounts(res.data.data || res.data))
      .catch(() => {})
      .finally(() => setLoading(false));
  }, []);

  const filtered = accounts.filter(a =>
    a.account_name?.toLowerCase().includes(search.toLowerCase()) ||
    a.bank_name?.toLowerCase().includes(search.toLowerCase())
  );

  return (
    <div className="p-8">
      <div className="flex items-center justify-between mb-8">
        <div>
          <h1 className="text-2xl font-bold text-white">Bank Accounts</h1>
          <p className="text-gray-400 mt-1">{accounts.length} accounts</p>
        </div>
        <button className="flex items-center gap-2 bg-blue-600 hover:bg-blue-700 text-white px-4 py-2 rounded-lg text-sm font-medium transition-colors">
          <Plus size={16} />
          Add Account
        </button>
      </div>

      <div className="bg-gray-900 rounded-xl border border-gray-800">
        <div className="p-4 border-b border-gray-800">
          <div className="relative">
            <Search size={16} className="absolute left-3 top-1/2 -translate-y-1/2 text-gray-400" />
            <input
              type="text"
              placeholder="Search accounts..."
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
                <th className="text-left text-xs font-medium text-gray-400 px-4 py-3">Account Name</th>
                <th className="text-left text-xs font-medium text-gray-400 px-4 py-3">Bank</th>
                <th className="text-left text-xs font-medium text-gray-400 px-4 py-3">Account Number</th>
                <th className="text-left text-xs font-medium text-gray-400 px-4 py-3">Currency</th>
                <th className="text-left text-xs font-medium text-gray-400 px-4 py-3">SWIFT</th>
                <th className="text-left text-xs font-medium text-gray-400 px-4 py-3">Status</th>
              </tr>
            </thead>
            <tbody>
              {loading ? (
                [...Array(3)].map((_, i) => (
                  <tr key={i} className="border-b border-gray-800">
                    {[...Array(6)].map((_, j) => (
                      <td key={j} className="px-4 py-3"><div className="h-4 bg-gray-800 rounded animate-pulse" /></td>
                    ))}
                  </tr>
                ))
              ) : filtered.length === 0 ? (
                <tr>
                  <td colSpan={6} className="py-16 text-center">
                    <Building2 size={40} className="text-gray-700 mx-auto mb-3" />
                    <p className="text-gray-400">No bank accounts found</p>
                  </td>
                </tr>
              ) : (
                filtered.map(a => (
                  <tr key={a.id} className="border-b border-gray-800 hover:bg-gray-800/50 transition-colors">
                    <td className="px-4 py-3 text-white text-sm font-medium">{a.account_name}</td>
                    <td className="px-4 py-3 text-gray-300 text-sm">{a.bank_name}</td>
                    <td className="px-4 py-3 text-blue-400 text-sm font-mono">{a.account_number}</td>
                    <td className="px-4 py-3"><span className="text-xs bg-gray-800 text-gray-300 px-2 py-1 rounded-full">{a.currency}</span></td>
                    <td className="px-4 py-3 text-gray-400 text-sm font-mono">{a.swift_code}</td>
                    <td className="px-4 py-3">
                      <span className={`text-xs px-2 py-1 rounded-full ${a.is_active ? 'bg-green-900/40 text-green-400' : 'bg-red-900/40 text-red-400'}`}>
                        {a.is_active ? 'Active' : 'Inactive'}
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
