'use client';
import { useEffect, useState } from 'react';
import { Plus, Search, Edit, Trash2, X } from 'lucide-react';
import { useCrud } from '@/hooks/useCrud';
import { ConfirmDialog } from '@/components/confirm-dialog';

interface ExchangeRate {
  id: string;
  from_currency: 'USD' | 'EUR' | 'AED' | 'EGP';
  to_currency: 'USD' | 'EUR' | 'AED' | 'EGP';
  rate: number;
  effective_date: string;
  created_by?: string;
}

const initialFormState = {
  from_currency: 'USD' as const,
  to_currency: 'EUR' as const,
  rate: 0,
  effective_date: new Date().toISOString().split('T')[0],
};

export default function ExchangeRatesPage() {
  const { state, saving, fetchItems, createItem, updateItem, deleteItem } = useCrud<ExchangeRate>({
    baseUrl: '/api/v1/exchange-rates',
  });

  const [search, setSearch] = useState('');
  const [showModal, setShowModal] = useState(false);
  const [editingId, setEditingId] = useState<string | null>(null);
  const [form, setForm] = useState(initialFormState);
  const [deleteConfirm, setDeleteConfirm] = useState<{ isOpen: boolean; id: string | null }>({
    isOpen: false,
    id: null,
  });

  useEffect(() => {
    fetchItems(1, 50);
  }, []);

  const handleOpenModal = (rate?: ExchangeRate) => {
    if (rate) {
      setEditingId(rate.id);
      setForm({
        from_currency: rate.from_currency,
        to_currency: rate.to_currency,
        rate: rate.rate,
        effective_date: rate.effective_date,
      });
    } else {
      setEditingId(null);
      setForm(initialFormState);
    }
    setShowModal(true);
  };

  const handleCloseModal = () => {
    setShowModal(false);
    setEditingId(null);
    setForm(initialFormState);
  };

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    try {
      if (editingId) {
        await updateItem(editingId, form);
        fetchItems(1, 50);
      } else {
        await createItem(form);
        fetchItems(1, 50);
      }
      handleCloseModal();
    } catch (error) {}
  };

  const handleDelete = async () => {
    if (!deleteConfirm.id) return;
    try {
      await deleteItem(deleteConfirm.id);
      fetchItems(1, 50);
      setDeleteConfirm({ isOpen: false, id: null });
    } catch (error) {}
  };

  const filtered = state.items.filter(
    (r) =>
      `${r.from_currency}/${r.to_currency}`.toLowerCase().includes(search.toLowerCase()) ||
      r.rate.toString().includes(search)
  );

  return (
    <div className="p-8">
      <div className="flex items-center justify-between mb-8">
        <div>
          <h1 className="text-2xl font-bold text-white">Exchange Rates</h1>
          <p className="text-gray-400 mt-1">{state.total} rates total</p>
        </div>
        <button
          onClick={() => handleOpenModal()}
          className="flex items-center gap-2 bg-blue-600 hover:bg-blue-700 text-white px-4 py-2 rounded-lg text-sm font-medium transition-colors"
        >
          <Plus size={16} />
          Add Rate
        </button>
      </div>

      <div className="bg-gray-900 rounded-xl border border-gray-800">
        <div className="p-4 border-b border-gray-800">
          <div className="relative">
            <Search size={16} className="absolute left-3 top-1/2 -translate-y-1/2 text-gray-400" />
            <input
              type="text"
              placeholder="Search rates..."
              value={search}
              onChange={(e) => setSearch(e.target.value)}
              className="w-full bg-gray-800 border border-gray-700 text-white rounded-lg pl-9 pr-4 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500"
            />
          </div>
        </div>
        <div className="overflow-x-auto">
          <table className="w-full">
            <thead>
              <tr className="border-b border-gray-800">
                <th className="text-left text-xs font-medium text-gray-400 px-4 py-3">Currency Pair</th>
                <th className="text-left text-xs font-medium text-gray-400 px-4 py-3">Rate</th>
                <th className="text-left text-xs font-medium text-gray-400 px-4 py-3">Effective Date</th>
                <th className="text-left text-xs font-medium text-gray-400 px-4 py-3">Created By</th>
                <th className="text-left text-xs font-medium text-gray-400 px-4 py-3">Actions</th>
              </tr>
            </thead>
            <tbody>
              {state.loading ? (
                [...Array(5)].map((_, i) => (
                  <tr key={i} className="border-b border-gray-800">
                    {[...Array(5)].map((_, j) => (
                      <td key={j} className="px-4 py-3">
                        <div className="h-4 bg-gray-800 rounded animate-pulse" />
                      </td>
                    ))}
                  </tr>
                ))
              ) : filtered.length === 0 ? (
                <tr>
                  <td colSpan={5} className="text-center text-gray-400 py-12">
                    No rates found
                  </td>
                </tr>
              ) : (
                filtered.map((r) => (
                  <tr key={r.id} className="border-b border-gray-800 hover:bg-gray-800/50 transition-colors">
                    <td className="px-4 py-3 text-white text-sm font-medium">
                      {r.from_currency}/{r.to_currency}
                    </td>
                    <td className="px-4 py-3 text-white text-sm font-medium">{r.rate.toFixed(4)}</td>
                    <td className="px-4 py-3 text-gray-400 text-sm">{r.effective_date}</td>
                    <td className="px-4 py-3 text-gray-400 text-sm">{r.created_by || '-'}</td>
                    <td className="px-4 py-3">
                      <div className="flex items-center gap-2">
                        <button
                          onClick={() => handleOpenModal(r)}
                          className="text-gray-500 hover:text-blue-400 transition-colors"
                        >
                          <Edit size={15} />
                        </button>
                        <button
                          onClick={() => setDeleteConfirm({ isOpen: true, id: r.id })}
                          className="text-gray-500 hover:text-red-400 transition-colors"
                        >
                          <Trash2 size={15} />
                        </button>
                      </div>
                    </td>
                  </tr>
                ))
              )}
            </tbody>
          </table>
        </div>
      </div>

      {showModal && (
        <div className="fixed inset-0 bg-black/60 flex items-center justify-center z-50 p-4">
          <div className="bg-gray-900 rounded-2xl border border-gray-800 w-full max-w-lg max-h-[90vh] overflow-y-auto">
            <div className="flex items-center justify-between p-6 border-b border-gray-800">
              <h2 className="text-lg font-semibold text-white">
                {editingId ? 'Edit Rate' : 'Add Rate'}
              </h2>
              <button onClick={handleCloseModal} disabled={saving} className="text-gray-400 hover:text-white disabled:opacity-50">
                <X size={20} />
              </button>
            </div>
            <form onSubmit={handleSubmit} className="p-6 space-y-4">
              <div className="grid grid-cols-2 gap-4">
                <div>
                  <label className="block text-sm font-medium text-gray-300 mb-1.5">From</label>
                  <select
                    value={form.from_currency}
                    onChange={(e) => setForm({ ...form, from_currency: e.target.value as any })}
                    className="w-full bg-gray-800 border border-gray-700 text-white rounded-lg px-4 py-2.5 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500"
                  >
                    <option value="USD">USD</option>
                    <option value="EUR">EUR</option>
                    <option value="AED">AED</option>
                    <option value="EGP">EGP</option>
                  </select>
                </div>
                <div>
                  <label className="block text-sm font-medium text-gray-300 mb-1.5">To</label>
                  <select
                    value={form.to_currency}
                    onChange={(e) => setForm({ ...form, to_currency: e.target.value as any })}
                    className="w-full bg-gray-800 border border-gray-700 text-white rounded-lg px-4 py-2.5 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500"
                  >
                    <option value="USD">USD</option>
                    <option value="EUR">EUR</option>
                    <option value="AED">AED</option>
                    <option value="EGP">EGP</option>
                  </select>
                </div>
              </div>
              <input
                required
                type="number"
                step="0.0001"
                value={form.rate}
                onChange={(e) => setForm({ ...form, rate: parseFloat(e.target.value) })}
                className="w-full bg-gray-800 border border-gray-700 text-white rounded-lg px-4 py-2.5 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500"
                placeholder="Exchange Rate"
              />
              <input
                required
                type="date"
                value={form.effective_date}
                onChange={(e) => setForm({ ...form, effective_date: e.target.value })}
                className="w-full bg-gray-800 border border-gray-700 text-white rounded-lg px-4 py-2.5 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500"
              />
              <div className="flex gap-3 pt-2">
                <button
                  type="button"
                  onClick={handleCloseModal}
                  disabled={saving}
                  className="flex-1 bg-gray-800 hover:bg-gray-700 disabled:bg-gray-800 disabled:opacity-50 text-white py-2.5 rounded-lg text-sm font-medium transition-colors"
                >
                  Cancel
                </button>
                <button
                  type="submit"
                  disabled={saving}
                  className="flex-1 bg-blue-600 hover:bg-blue-700 disabled:bg-blue-800 text-white py-2.5 rounded-lg text-sm font-medium transition-colors"
                >
                  {saving ? 'Saving...' : editingId ? 'Update' : 'Add'}
                </button>
              </div>
            </form>
          </div>
        </div>
      )}

      <ConfirmDialog
        isOpen={deleteConfirm.isOpen}
        title="Delete Rate"
        message="Are you sure you want to delete this exchange rate?"
        confirmText="Delete"
        cancelText="Cancel"
        isDangerous={true}
        isLoading={saving}
        onConfirm={handleDelete}
        onCancel={() => setDeleteConfirm({ isOpen: false, id: null })}
      />
    </div>
  );
}
