'use client';

import { useEffect, useState } from 'react';
import api from '@/lib/api';
import { Plus, Search, CheckCircle, XCircle } from 'lucide-react';

interface User {
  id: string;
  email: string;
  full_name: string;
  phone_number: string;
  is_active: boolean;
  is_email_verified: boolean;
  last_login: string;
  created_at: string;
  roles: any[];
}

export default function UsersPage() {
  const [users, setUsers] = useState<User[]>([]);
  const [loading, setLoading] = useState(true);
  const [search, setSearch] = useState('');
  const [total, setTotal] = useState(0);

  useEffect(() => {
    api.get('/api/v1/users?limit=50')
      .then(res => {
        setUsers(res.data.data || res.data);
        setTotal(res.data.total || 0);
      })
      .catch(() => {})
      .finally(() => setLoading(false));
  }, []);

  const filtered = users.filter(u =>
    u.full_name?.toLowerCase().includes(search.toLowerCase()) ||
    u.email?.toLowerCase().includes(search.toLowerCase())
  );

  return (
    <div className="p-8">
      <div className="flex items-center justify-between mb-8">
        <div>
          <h1 className="text-2xl font-bold text-white">Users</h1>
          <p className="text-gray-400 mt-1">{total} users total</p>
        </div>
        <button className="flex items-center gap-2 bg-blue-600 hover:bg-blue-700 text-white px-4 py-2 rounded-lg text-sm font-medium transition-colors">
          <Plus size={16} />
          Add User
        </button>
      </div>

      <div className="bg-gray-900 rounded-xl border border-gray-800">
        <div className="p-4 border-b border-gray-800">
          <div className="relative">
            <Search size={16} className="absolute left-3 top-1/2 -translate-y-1/2 text-gray-400" />
            <input
              type="text"
              placeholder="Search users..."
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
                <th className="text-left text-xs font-medium text-gray-400 px-4 py-3">Email</th>
                <th className="text-left text-xs font-medium text-gray-400 px-4 py-3">Roles</th>
                <th className="text-left text-xs font-medium text-gray-400 px-4 py-3">Verified</th>
                <th className="text-left text-xs font-medium text-gray-400 px-4 py-3">Status</th>
                <th className="text-left text-xs font-medium text-gray-400 px-4 py-3">Last Login</th>
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
                <tr><td colSpan={6} className="text-center text-gray-400 py-12">No users found</td></tr>
              ) : (
                filtered.map(u => (
                  <tr key={u.id} className="border-b border-gray-800 hover:bg-gray-800/50 transition-colors">
                    <td className="px-4 py-3">
                      <div className="flex items-center gap-2">
                        <div className="w-7 h-7 bg-blue-600 rounded-full flex items-center justify-center text-xs text-white font-semibold">
                          {u.full_name?.charAt(0) || u.email?.charAt(0)}
                        </div>
                        <span className="text-white text-sm">{u.full_name || '—'}</span>
                      </div>
                    </td>
                    <td className="px-4 py-3 text-gray-400 text-sm">{u.email}</td>
                    <td className="px-4 py-3">
                      {u.roles?.length > 0
                        ? u.roles.map((r: any) => (
                          <span key={r.id || r.name} className="text-xs bg-purple-900/40 text-purple-400 px-2 py-0.5 rounded-full mr-1">{r.name}</span>
                        ))
                        : <span className="text-gray-600 text-xs">No roles</span>
                      }
                    </td>
                    <td className="px-4 py-3">
                      {u.is_email_verified
                        ? <CheckCircle size={16} className="text-green-400" />
                        : <XCircle size={16} className="text-gray-600" />}
                    </td>
                    <td className="px-4 py-3">
                      <span className={`text-xs px-2 py-1 rounded-full ${u.is_active ? 'bg-green-900/40 text-green-400' : 'bg-red-900/40 text-red-400'}`}>
                        {u.is_active ? 'Active' : 'Inactive'}
                      </span>
                    </td>
                    <td className="px-4 py-3 text-gray-400 text-sm">
                      {u.last_login ? new Date(u.last_login).toLocaleDateString() : 'Never'}
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
