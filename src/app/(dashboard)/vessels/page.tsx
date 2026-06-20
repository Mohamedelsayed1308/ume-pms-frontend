'use client';

import { useEffect, useState } from 'react';
import { Plus, Search, Edit, Trash2, X } from 'lucide-react';
import { useCrud } from '@/hooks/useCrud';
import { ConfirmDialog } from '@/components/confirm-dialog';

interface Vessel {
  id: string;
  vessel_name: string;
  vessel_type: string;
  imo_number: string;
  flag: string;
  build_year: number;
  length: number;
  width: number;
  draft: number;
  capacity: number;
  is_active: boolean;
}

const VESSEL_TYPES = ['container_ship', 'bulk_carrier', 'tanker', 'general_cargo', 'roro'];

const initialFormState = {
  vessel_name: '',
  vessel_type: 'container_ship',
  imo_number: '',
  flag: '',
  build_year: new Date().getFullYear(),
  length: 0,
  width: 0,
  draft: 0,
  capacity: 0,
};

export default function VesselsPage() {
  const { state, saving, fetchItems, createItem, updateItem, deleteItem } = useCrud<Vessel>({
    baseUrl: '/api/v1/vessels',
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

  const handleOpenModal = (vessel?: Vessel) => {
    if (vessel) {
      setEditingId(vessel.id);
      setForm({
        vessel_name: vessel.vessel_name,
        vessel_type: vessel.vessel_type,
        imo_number: vessel.imo_number,
        flag: vessel.flag,
        build_year: vessel.build_year,
        length: vessel.length,
        width: vessel.width,
        draft: vessel.draft,
        capacity: vessel.capacity,
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
    (v) =>
      v.vessel_name?.toLowerCase().includes(search.toLowerCase()) ||
      v.imo_number?.toLowerCase().includes(search.toLowerCase())
  );

  return (
    <div className="p-8">
      <div className="flex items-center justify-between mb-8">
        <div>
          <h1 className="text-2xl font-bold text-white">Vessels</h1>
          <p className="text-gray-400 mt-1">{state.total} vessels total</p>
        </div>
        <button
          onClick={() => handleOpenModal()}
          className="flex items-center gap-2 bg-blue-600 hover:bg-blue-700 text-white px-4 py-2 rounded-lg text-sm font-medium transition-colors"
        >
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
                <th className="text-left text-xs font-medium text-gray-400 px-4 py-3">IMO</th>
                <th className="text-left text-xs font-medium text-gray-400 px-4 py-3">Flag</th>
                <th className="text-left text-xs font-medium text-gray-400 px-4 py-3">Capacity</th>
                <th className="text-left text-xs font-medium text-gray-400 px-4 py-3">Status</th>
                <th className="text-left text-xs font-medium text-gray-400 px-4 py-3">Actions</th>
              </tr>
            </thead>
            <tbody>
              {state.loading ? (
                [...Array(5)].map((_, i) => (
                  <tr key={i} className="border-b border-gray-800">
                    {[...Array(7)].map((_, j) => (
                      <td key={j} className="px-4 py-3">
                        <div className="h-4 bg-gray-800 rounded animate-pulse" />
                      </td>
                    ))}
                  </tr>
                ))
              ) : filtered.length === 0 ? (
                <tr>
                  <td colSpan={7} className="text-center text-gray-400 py-12">
                    No vessels found
                  </td>
                </tr>
              ) : (
                filtered.map((v) => (
                  <tr key={v.id} className="border-b border-gray-800 hover:bg-gray-800/50 transition-colors">
                    <td className="px-4 py-3 text-white text-sm font-medium">{v.vessel_name}</td>
                    <td className="px-4 py-3">
                      <span className="text-xs bg-gray-800 text-gray-300 px-2 py-1 rounded-full">
                        {v.vessel_type}
                      </span>
                    </td>
                    <td className="px-4 py-3 text-gray-400 text-sm">{v.imo_number}</td>
                    <td className="px-4 py-3 text-gray-400 text-sm">{v.flag}</td>
                    <td className="px-4 py-3 text-gray-400 text-sm">{v.capacity.toLocaleString()}</td>
                    <td className="px-4 py-3">
                      <span
                        className={`text-xs px-2 py-1 rounded-full ${
                          v.is_active
                            ? 'bg-green-900/40 text-green-400'
                            : 'bg-red-900/40 text-red-400'
                        }`}
                      >
                        {v.is_active ? 'Active' : 'Inactive'}
                      </span>
                    </td>
                    <td className="px-4 py-3">
                      <div className="flex items-center gap-2">
                        <button
                          onClick={() => handleOpenModal(v)}
                          className="text-gray-500 hover:text-blue-400 transition-colors"
                        >
                          <Edit size={15} />
                        </button>
                        <button
                          onClick={() => setDeleteConfirm({ isOpen: true, id: v.id })}
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
                {editingId ? 'Edit Vessel' : 'Add New Vessel'}
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
                <label className="block text-sm font-medium text-gray-300 mb-1.5">Vessel Name *</label>
                <input
                  required
                  value={form.vessel_name}
                  onChange={(e) => setForm({ ...form, vessel_name: e.target.value })}
                  className="w-full bg-gray-800 border border-gray-700 text-white rounded-lg px-4 py-2.5 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500"
                  placeholder="Vessel name"
                />
              </div>

              <div>
                <label className="block text-sm font-medium text-gray-300 mb-1.5">Type *</label>
                <select
                  required
                  value={form.vessel_type}
                  onChange={(e) => setForm({ ...form, vessel_type: e.target.value })}
                  className="w-full bg-gray-800 border border-gray-700 text-white rounded-lg px-4 py-2.5 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500"
                >
                  {VESSEL_TYPES.map((t) => (
                    <option key={t} value={t}>
                      {t.replace(/_/g, ' ')}
                    </option>
                  ))}
                </select>
              </div>

              <div className="grid grid-cols-2 gap-4">
                <div>
                  <label className="block text-sm font-medium text-gray-300 mb-1.5">IMO Number</label>
                  <input
                    value={form.imo_number}
                    onChange={(e) => setForm({ ...form, imo_number: e.target.value })}
                    className="w-full bg-gray-800 border border-gray-700 text-white rounded-lg px-4 py-2.5 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500"
                    placeholder="IMO number"
                  />
                </div>
                <div>
                  <label className="block text-sm font-medium text-gray-300 mb-1.5">Flag</label>
                  <input
                    value={form.flag}
                    onChange={(e) => setForm({ ...form, flag: e.target.value })}
                    className="w-full bg-gray-800 border border-gray-700 text-white rounded-lg px-4 py-2.5 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500"
                    placeholder="Flag"
                  />
                </div>
              </div>

              <div>
                <label className="block text-sm font-medium text-gray-300 mb-1.5">Build Year</label>
                <input
                  type="number"
                  value={form.build_year}
                  onChange={(e) => setForm({ ...form, build_year: parseInt(e.target.value) })}
                  className="w-full bg-gray-800 border border-gray-700 text-white rounded-lg px-4 py-2.5 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500"
                  placeholder="2020"
                />
              </div>

              <div className="grid grid-cols-2 gap-4">
                <div>
                  <label className="block text-sm font-medium text-gray-300 mb-1.5">Length (m)</label>
                  <input
                    type="number"
                    step="0.1"
                    value={form.length}
                    onChange={(e) => setForm({ ...form, length: parseFloat(e.target.value) })}
                    className="w-full bg-gray-800 border border-gray-700 text-white rounded-lg px-4 py-2.5 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500"
                    placeholder="0"
                  />
                </div>
                <div>
                  <label className="block text-sm font-medium text-gray-300 mb-1.5">Width (m)</label>
                  <input
                    type="number"
                    step="0.1"
                    value={form.width}
                    onChange={(e) => setForm({ ...form, width: parseFloat(e.target.value) })}
                    className="w-full bg-gray-800 border border-gray-700 text-white rounded-lg px-4 py-2.5 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500"
                    placeholder="0"
                  />
                </div>
              </div>

              <div className="grid grid-cols-2 gap-4">
                <div>
                  <label className="block text-sm font-medium text-gray-300 mb-1.5">Draft (m)</label>
                  <input
                    type="number"
                    step="0.1"
                    value={form.draft}
                    onChange={(e) => setForm({ ...form, draft: parseFloat(e.target.value) })}
                    className="w-full bg-gray-800 border border-gray-700 text-white rounded-lg px-4 py-2.5 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500"
                    placeholder="0"
                  />
                </div>
                <div>
                  <label className="block text-sm font-medium text-gray-300 mb-1.5">Capacity (TEU)</label>
                  <input
                    type="number"
                    value={form.capacity}
                    onChange={(e) => setForm({ ...form, capacity: parseFloat(e.target.value) })}
                    className="w-full bg-gray-800 border border-gray-700 text-white rounded-lg px-4 py-2.5 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500"
                    placeholder="0"
                  />
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
                  {saving ? 'Saving...' : editingId ? 'Update Vessel' : 'Add Vessel'}
                </button>
              </div>
            </form>
          </div>
        </div>
      )}

      {/* Delete Confirmation */}
      <ConfirmDialog
        isOpen={deleteConfirm.isOpen}
        title="Delete Vessel"
        message="Are you sure you want to delete this vessel? This action cannot be undone."
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
