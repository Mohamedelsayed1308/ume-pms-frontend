'use client';

import { useEffect, useState } from 'react';
import { Plus, Search, Edit, Trash2, X, CheckCircle, XCircle } from 'lucide-react';
import { useCrud } from '@/hooks/useCrud';
import { ConfirmDialog } from '@/components/confirm-dialog';

interface Supplier {
  id: string;
  name: string;
  supplier_type: string;
  contact_email: string;
  contact_phone: string;
  address: string;
  city: string;
  country: string;
  payment_terms: string;
  currency: string;
  is_approved: boolean;
  is_active: boolean;
}

const SUPPLIER_TYPES = ['local', 'international'];
const PAYMENT_TERMS = ['advance', 'net_30', 'net_60', 'net_90'];
const CURRENCIES = ['USD', 'EUR', 'AED', 'EGP'];

const initialFormState = {
  name: '',
  supplier_type: 'local',
  contact_email: '',
  contact_phone: '',
  address: '',
  city: '',
  country: '',
  payment_terms: 'net_30',
  currency: 'USD',
};

export default function SuppliersPage() {
  const { state, saving, fetchItems, createItem, updateItem, deleteItem } = useCrud<Supplier>({
    baseUrl: '/api/v1/suppliers',
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

  const handleOpenModal = (supplier?: Supplier) => {
    if (supplier) {
      setEditingId(supplier.id);
      setForm({
        name: supplier.name,
        supplier_type: supplier.supplier_type,
        contact_email: supplier.contact_email,
        contact_phone: supplier.contact_phone,
        address: supplier.address,
        city: supplier.city,
        country: supplier.country,
        payment_terms: supplier.payment_terms,
        currency: supplier.currency,
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
    } catch (error) {
      // Error is handled by the hook
    }
  };

  const handleDelete = async () => {
    if (!deleteConfirm.id) return;
    try {
      await deleteItem(deleteConfirm.id);
      fetchItems(1, 50);
      setDeleteConfirm({ isOpen: false, id: null });
    } catch (error) {
      // Error is handled by the hook
    }
  };

  const filtered = state.items.filter(
    (s) =>
      s.name?.toLowerCase().includes(search.toLowerCase()) ||
      s.contact_email?.toLowerCase().includes(search.toLowerCase())
  );

  return (
    <div className="p-8">
      <div className="flex items-center justify-between mb-8">
        <div>
          <h1 className="text-2xl font-bold text-white">Suppliers</h1>
          <p className="text-gray-400 mt-1">{state.total} suppliers total</p>
        </div>
        <button
          onClick={() => handleOpenModal()}
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
              onChange={(e) => setSearch(e.target.value)}
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
                <th className="text-left text-xs font-medium text-gray-400 px-4 py-3">Status</th>
                <th className="text-left text-xs font-medium text-gray-400 px-4 py-3">Actions</th>
              </tr>
            </thead>
            <tbody>
              {state.loading ? (
                [...Array(5)].map((_, i) => (
                  <tr key={i} className="border-b border-gray-800">
                    {[...Array(6)].map((_, j) => (
                      <td key={j} className="px-4 py-3">
                        <div className="h-4 bg-gray-800 rounded animate-pulse" />
                      </td>
                    ))}
                  </tr>
                ))
              ) : filtered.length === 0 ? (
                <tr>
                  <td colSpan={6} className="text-center text-gray-400 py-12">
                    No suppliers found
                  </td>
                </tr>
              ) : (
                filtered.map((s) => (
                  <tr key={s.id} className="border-b border-gray-800 hover:bg-gray-800/50 transition-colors">
                    <td className="px-4 py-3 text-white text-sm font-medium">{s.name}</td>
                    <td className="px-4 py-3">
                      <span className="text-xs bg-gray-800 text-gray-300 px-2 py-1 rounded-full">
                        {s.supplier_type}
                      </span>
                    </td>
                    <td className="px-4 py-3 text-gray-400 text-sm">{s.contact_email}</td>
                    <td className="px-4 py-3 text-gray-400 text-sm">{s.country}</td>
                    <td className="px-4 py-3">
                      <span
                        className={`text-xs px-2 py-1 rounded-full ${
                          s.is_active
                            ? 'bg-green-900/40 text-green-400'
                            : 'bg-red-900/40 text-red-400'
                        }`}
                      >
                        {s.is_active ? 'Active' : 'Inactive'}
                      </span>
                    </td>
                    <td className="px-4 py-3">
                      <div className="flex items-center gap-2">
                        <button
                          onClick={() => handleOpenModal(s)}
                          className="text-gray-500 hover:text-blue-400 transition-colors"
                        >
                          <Edit size={15} />
                        </button>
                        <button
                          onClick={() => setDeleteConfirm({ isOpen: true, id: s.id })}
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

      {/* Modal */}
      {showModal && (
        <div className="fixed inset-0 bg-black/60 flex items-center justify-center z-50 p-4">
          <div className="bg-gray-900 rounded-2xl border border-gray-800 w-full max-w-lg max-h-[90vh] overflow-y-auto">
            <div className="flex items-center justify-between p-6 border-b border-gray-800">
              <h2 className="text-lg font-semibold text-white">
                {editingId ? 'Edit Supplier' : 'Add New Supplier'}
              </h2>
              <button
                onClick={handleCloseModal}
                disabled={saving}
                className="text-gray-400 hover:text-white disabled:opacity-50"
              >
                <X size={20} />
              </button>
            </div>
            <form onSubmit={handleSubmit} className="p-6 space-y-4">
              <div>
                <label className="block text-sm font-medium text-gray-300 mb-1.5">Name *</label>
                <input
                  required
                  value={form.name}
                  onChange={(e) => setForm({ ...form, name: e.target.value })}
                  className="w-full bg-gray-800 border border-gray-700 text-white rounded-lg px-4 py-2.5 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500"
                  placeholder="Supplier name"
                />
              </div>

              <div>
                <label className="block text-sm font-medium text-gray-300 mb-1.5">Type *</label>
                <select
                  required
                  value={form.supplier_type}
                  onChange={(e) => setForm({ ...form, supplier_type: e.target.value })}
                  className="w-full bg-gray-800 border border-gray-700 text-white rounded-lg px-4 py-2.5 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500"
                >
                  {SUPPLIER_TYPES.map((t) => (
                    <option key={t} value={t}>
                      {t.replace('_', ' ')}
                    </option>
                  ))}
                </select>
              </div>

              <div className="grid grid-cols-2 gap-4">
                <div>
                  <label className="block text-sm font-medium text-gray-300 mb-1.5">Email</label>
                  <input
                    type="email"
                    value={form.contact_email}
                    onChange={(e) => setForm({ ...form, contact_email: e.target.value })}
                    className="w-full bg-gray-800 border border-gray-700 text-white rounded-lg px-4 py-2.5 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500"
                    placeholder="email@example.com"
                  />
                </div>
                <div>
                  <label className="block text-sm font-medium text-gray-300 mb-1.5">Phone</label>
                  <input
                    value={form.contact_phone}
                    onChange={(e) => setForm({ ...form, contact_phone: e.target.value })}
                    className="w-full bg-gray-800 border border-gray-700 text-white rounded-lg px-4 py-2.5 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500"
                    placeholder="+1234567890"
                  />
                </div>
              </div>

              <div>
                <label className="block text-sm font-medium text-gray-300 mb-1.5">Address</label>
                <input
                  value={form.address}
                  onChange={(e) => setForm({ ...form, address: e.target.value })}
                  className="w-full bg-gray-800 border border-gray-700 text-white rounded-lg px-4 py-2.5 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500"
                  placeholder="Street address"
                />
              </div>

              <div className="grid grid-cols-2 gap-4">
                <div>
                  <label className="block text-sm font-medium text-gray-300 mb-1.5">City</label>
                  <input
                    value={form.city}
                    onChange={(e) => setForm({ ...form, city: e.target.value })}
                    className="w-full bg-gray-800 border border-gray-700 text-white rounded-lg px-4 py-2.5 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500"
                    placeholder="City"
                  />
                </div>
                <div>
                  <label className="block text-sm font-medium text-gray-300 mb-1.5">Country</label>
                  <input
                    value={form.country}
                    onChange={(e) => setForm({ ...form, country: e.target.value })}
                    className="w-full bg-gray-800 border border-gray-700 text-white rounded-lg px-4 py-2.5 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500"
                    placeholder="Egypt"
                  />
                </div>
              </div>

              <div className="grid grid-cols-2 gap-4">
                <div>
                  <label className="block text-sm font-medium text-gray-300 mb-1.5">Payment Terms *</label>
                  <select
                    required
                    value={form.payment_terms}
                    onChange={(e) => setForm({ ...form, payment_terms: e.target.value })}
                    className="w-full bg-gray-800 border border-gray-700 text-white rounded-lg px-4 py-2.5 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500"
                  >
                    {PAYMENT_TERMS.map((t) => (
                      <option key={t} value={t}>
                        {t.replace('_', ' ').toUpperCase()}
                      </option>
                    ))}
                  </select>
                </div>
                <div>
                  <label className="block text-sm font-medium text-gray-300 mb-1.5">Currency *</label>
                  <select
                    required
                    value={form.currency}
                    onChange={(e) => setForm({ ...form, currency: e.target.value })}
                    className="w-full bg-gray-800 border border-gray-700 text-white rounded-lg px-4 py-2.5 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500"
                  >
                    {CURRENCIES.map((c) => (
                      <option key={c} value={c}>
                        {c}
                      </option>
                    ))}
                  </select>
                </div>
              </div>

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
                  {saving ? 'Saving...' : editingId ? 'Update Supplier' : 'Add Supplier'}
                </button>
              </div>
            </form>
          </div>
        </div>
      )}

      {/* Delete Confirmation */}
      <ConfirmDialog
        isOpen={deleteConfirm.isOpen}
        title="Delete Supplier"
        message="Are you sure you want to delete this supplier? This action cannot be undone."
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
