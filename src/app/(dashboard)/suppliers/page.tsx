'use client';

import { useEffect, useState } from 'react';
import api from '@/lib/api';
import { Plus, Search, CheckCircle, XCircle, Trash2, X } from 'lucide-react';

interface Supplier {
  id: string;
  name: string;
  supplier_type: string;
  email: string;
  phone: string;
  country: string;
  is_approved: boolean;
  is_active: boolean;
}

const SUPPLIER_TYPES = ['local', 'international'];
const PAYMENT_TERMS = ['advance', 'net_30', 'net_60', 'net_90'];
const CURRENCIES = ['USD', 'EUR', 'AED', 'EGP'];

export default function SuppliersPage() {
  const [suppliers, setSuppliers] = useState<Supplier[]>([]);
  const [loading, setLoading] = useState(true);
  const [search, setSearch] = useState('');
  const [total, setTotal] = useState(0);
  const [showModal, setShowModal] = useState(false);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState('');
  const [form, setForm] = useState({
    name: '', supplier_type: 'local', contact_email: '', contact_phone: '',
    address: '', city: '', country: '', payment_terms: 'net_30', currency: 'USD',
  });

  const fetchSuppliers = () => {
    setLoading(true);
    api.get('/api/v1/suppliers?limit=50')
      .then(res => {
        setSuppliers(res.data.data || res.data);
        setTotal(res.data.total || 0);
      })
      .catch(() => {})
      .finally(() => setLoading(false));
  };

  useEffect(() => { fetchSuppliers(); }, []);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setSaving(true);
    setError('');
    try {
      await api.post('/api/v1/suppliers', form);
      setShowModal(false);
      setForm({ name: '', supplier_type: 'local', contact_email: '', contact_phone: '', address: '', city: '', country: '', payment_terms: 'net_30', currency: 'USD' });
      fetchSuppliers();
    } catch (err: any) {
      const msg = err.response?.data?.message;
      setError(Array.isArray(msg) ? msg.join(', ') : msg || 'Failed to create supplier');
    } finally {
      setSaving(false);
    }
  };

  const filtered = suppliers.filter(s =>
    s.name?.toLowerCase().includes(search.toLowerCase()) ||
    s.email?.toLowerCase().includes(search.toLowerCase())
  );

  return (
    <div className="p-8">
      <div className="flex items-center justify-between mb-8">
        <div>
          <h1 className="text-2xl font-bold text-white">Suppliers</h1>
          <p className="text-gray-400 mt-1">{total} suppliers total</p>
        </div>
        <button
          onClick={() => setShowModal(true)}
          className="flex items-center gap-2 bg-blue-600 hover:bg-blue-700 text-white px-4 py-2 rounded-lg text-sm font-medium transition-colors"
        >
          <Plus size={16} />
          Add Supplier
        </button>
      </div>

      <div className="bg-gray-900 rounded-xl border border-gray-800">
        <div className="p-4 border-b border-gray-800">
          <div className="relative">
            <Search size={16} className="absolute left-3 top-1/2 -translate-y-1/2 text-gray-400" />
            <input
              type="text"
              placeholder="Search suppliers..."
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
                <th className="text-left text-xs font-medium text-gray-400 px-4 py-3">Type</th>
                <th className="text-left text-xs font-medium text-gray-400 px-4 py-3">Email</th>
                <th className="text-left text-xs font-medium text-gray-400 px-4 py-3">Country</th>
                <th className="text-left text-xs font-medium text-gray-400 px-4 py-3">Approved</th>
                <th className="text-left text-xs font-medium text-gray-400 px-4 py-3">Status</th>
                <th className="text-left text-xs font-medium text-gray-400 px-4 py-3">Actions</th>
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
                <tr><td colSpan={7} className="text-center text-gray-400 py-12">No suppliers found</td></tr>
              ) : (
                filtered.map(s => (
                  <tr key={s.id} className="border-b border-gray-800 hover:bg-gray-800/50 transition-colors">
                    <td className="px-4 py-3 text-white text-sm font-medium">{s.name}</td>
                    <td className="px-4 py-3"><span className="text-xs bg-gray-800 text-gray-300 px-2 py-1 rounded-full">{s.supplier_type}</span></td>
                    <td className="px-4 py-3 text-gray-400 text-sm">{s.email}</td>
                    <td className="px-4 py-3 text-gray-400 text-sm">{s.country}</td>
                    <td className="px-4 py-3">{s.is_approved ? <CheckCircle size={16} className="text-green-400" /> : <XCircle size={16} className="text-gray-600" />}</td>
                    <td className="px-4 py-3">
                      <span className={`text-xs px-2 py-1 rounded-full ${s.is_active ? 'bg-green-900/40 text-green-400' : 'bg-red-900/40 text-red-400'}`}>
                        {s.is_active ? 'Active' : 'Inactive'}
                      </span>
                    </td>
                    <td className="px-4 py-3">
                      <button className="text-gray-500 hover:text-red-400 transition-colors"><Trash2 size={15} /></button>
                    </td>
                  </tr>
                ))
              )}
            </tbody>
          </table>
        </div>
      </div>

      {/* Modal */}
      {showModal && (
        <div className="fixed inset-0 bg-black/60 flex items-center justify-center z-50 p-4">
          <div className="bg-gray-900 rounded-2xl border border-gray-800 w-full max-w-lg max-h-[90vh] overflow-y-auto">
            <div className="flex items-center justify-between p-6 border-b border-gray-800">
              <h2 className="text-lg font-semibold text-white">Add New Supplier</h2>
              <button onClick={() => setShowModal(false)} className="text-gray-400 hover:text-white">
                <X size={20} />
              </button>
            </div>
            <form onSubmit={handleSubmit} className="p-6 space-y-4">
              {error && <div className="bg-red-900/30 border border-red-700 text-red-400 px-4 py-3 rounded-lg text-sm">{error}</div>}

              <div>
                <label className="block text-sm font-medium text-gray-300 mb-1.5">Name *</label>
                <input required value={form.name} onChange={e => setForm({...form, name: e.target.value})}
                  className="w-full bg-gray-800 border border-gray-700 text-white rounded-lg px-4 py-2.5 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500"
                  placeholder="Supplier name" />
              </div>

              <div>
                <label className="block text-sm font-medium text-gray-300 mb-1.5">Type *</label>
                <select required value={form.supplier_type} onChange={e => setForm({...form, supplier_type: e.target.value})}
                  className="w-full bg-gray-800 border border-gray-700 text-white rounded-lg px-4 py-2.5 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500">
                  {SUPPLIER_TYPES.map(t => <option key={t} value={t}>{t.replace('_', ' ')}</option>)}
                </select>
              </div>

              <div className="grid grid-cols-2 gap-4">
                <div>
                  <label className="block text-sm font-medium text-gray-300 mb-1.5">Email</label>
                  <input type="email" value={form.contact_email} onChange={e => setForm({...form, contact_email: e.target.value})}
                    className="w-full bg-gray-800 border border-gray-700 text-white rounded-lg px-4 py-2.5 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500"
                    placeholder="email@example.com" />
                </div>
                <div>
                  <label className="block text-sm font-medium text-gray-300 mb-1.5">Phone</label>
                  <input value={form.contact_phone} onChange={e => setForm({...form, contact_phone: e.target.value})}
                    className="w-full bg-gray-800 border border-gray-700 text-white rounded-lg px-4 py-2.5 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500"
                    placeholder="+1234567890" />
                </div>
              </div>

              <div className="grid grid-cols-2 gap-4">
                <div>
                  <label className="block text-sm font-medium text-gray-300 mb-1.5">City</label>
                  <input value={form.city} onChange={e => setForm({...form, city: e.target.value})}
                    className="w-full bg-gray-800 border border-gray-700 text-white rounded-lg px-4 py-2.5 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500"
                    placeholder="City" />
                </div>
                <div>
                  <label className="block text-sm font-medium text-gray-300 mb-1.5">Country</label>
                  <input value={form.country} onChange={e => setForm({...form, country: e.target.value})}
                    className="w-full bg-gray-800 border border-gray-700 text-white rounded-lg px-4 py-2.5 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500"
                    placeholder="Egypt" />
                </div>
              </div>

              <div className="grid grid-cols-2 gap-4">
                <div>
                  <label className="block text-sm font-medium text-gray-300 mb-1.5">Payment Terms *</label>
                  <select required value={form.payment_terms} onChange={e => setForm({...form, payment_terms: e.target.value})}
                    className="w-full bg-gray-800 border border-gray-700 text-white rounded-lg px-4 py-2.5 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500">
                    {PAYMENT_TERMS.map(t => <option key={t} value={t}>{t.replace('_', ' ').toUpperCase()}</option>)}
                  </select>
                </div>
                <div>
                  <label className="block text-sm font-medium text-gray-300 mb-1.5">Currency *</label>
                  <select required value={form.currency} onChange={e => setForm({...form, currency: e.target.value})}
                    className="w-full bg-gray-800 border border-gray-700 text-white rounded-lg px-4 py-2.5 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500">
                    {CURRENCIES.map(c => <option key={c} value={c}>{c}</option>)}
                  </select>
                </div>
              </div>

              <div className="flex gap-3 pt-2">
                <button type="button" onClick={() => setShowModal(false)}
                  className="flex-1 bg-gray-800 hover:bg-gray-700 text-white py-2.5 rounded-lg text-sm font-medium transition-colors">
                  Cancel
                </button>
                <button type="submit" disabled={saving}
                  className="flex-1 bg-blue-600 hover:bg-blue-700 disabled:bg-blue-800 text-white py-2.5 rounded-lg text-sm font-medium transition-colors">
                  {saving ? 'Saving...' : 'Add Supplier'}
                </button>
              </div>
            </form>
          </div>
        </div>
      )}
    </div>
  );
}
