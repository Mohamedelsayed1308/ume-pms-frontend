'use client';

import { useEffect, useState } from 'react';
import { Plus, Search, Edit, Trash2, X } from 'lucide-react';
import { useCrud } from '@/hooks/useCrud';
import { ConfirmDialog } from '@/components/confirm-dialog';

interface InvoiceItem {
  id?: string;
  description: string;
  quantity: number;
  unit_price: number;
  total_price?: number;
}

interface Invoice {
  id: string;
  invoice_number: string;
  po_id?: string;
  supplier_id: string;
  vessel_id?: string;
  invoice_date: string;
  due_date: string;
  status: 'draft' | 'pending_approval' | 'approved' | 'rejected' | 'paid' | 'partially_paid' | 'cancelled';
  total_amount: number;
  paid_amount: number;
  remaining_amount: number;
  currency: 'USD' | 'EUR' | 'AED' | 'EGP';
  notes?: string;
  items?: InvoiceItem[];
  supplier?: { id: string; name: string };
  vessel?: { id: string; vessel_name: string };
}

const initialFormState = {
  po_id: '',
  supplier_id: '',
  vessel_id: '',
  invoice_date: new Date().toISOString().split('T')[0],
  due_date: new Date(Date.now() + 30 * 24 * 60 * 60 * 1000).toISOString().split('T')[0],
  currency: 'USD' as const,
  notes: '',
  items: [{ description: '', quantity: 1, unit_price: 0 }],
};

export default function InvoicesPage() {
  const { state, saving, fetchItems, createItem, updateItem, deleteItem } = useCrud<Invoice>({
    baseUrl: '/api/v1/invoices',
  });

  const [search, setSearch] = useState('');
  const [showModal, setShowModal] = useState(false);
  const [editingId, setEditingId] = useState<string | null>(null);
  const [form, setForm] = useState(initialFormState);
  const [suppliers, setSuppliers] = useState<any[]>([]);
  const [vessels, setVessels] = useState<any[]>([]);
  const [deleteConfirm, setDeleteConfirm] = useState<{ isOpen: boolean; id: string | null }>({
    isOpen: false,
    id: null,
  });

  useEffect(() => {
    fetchItems(1, 50);
    fetch('http://localhost:3001/api/v1/suppliers?limit=100')
      .then((r) => r.json())
      .then((d) => setSuppliers(d.data || []))
      .catch(() => {});
    fetch('http://localhost:3001/api/v1/vessels?limit=100')
      .then((r) => r.json())
      .then((d) => setVessels(d.data || []))
      .catch(() => {});
  }, []);

  const handleOpenModal = (invoice?: Invoice) => {
    if (invoice) {
      setEditingId(invoice.id);
      setForm({
        po_id: invoice.po_id || '',
        supplier_id: invoice.supplier_id,
        vessel_id: invoice.vessel_id || '',
        invoice_date: invoice.invoice_date,
        due_date: invoice.due_date,
        currency: invoice.currency,
        notes: invoice.notes || '',
        items: invoice.items || [{ description: '', quantity: 1, unit_price: 0 }],
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

  const handleAddItem = () => {
    setForm({
      ...form,
      items: [...form.items, { description: '', quantity: 1, unit_price: 0 }],
    });
  };

  const handleRemoveItem = (index: number) => {
    setForm({
      ...form,
      items: form.items.filter((_, i) => i !== index),
    });
  };

  const handleItemChange = (index: number, field: string, value: any) => {
    const newItems = [...form.items];
    newItems[index] = { ...newItems[index], [field]: value };
    setForm({ ...form, items: newItems });
  };

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (form.items.length === 0) {
      alert('Add at least one item');
      return;
    }
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
    (inv) =>
      inv.invoice_number?.toLowerCase().includes(search.toLowerCase()) ||
      inv.supplier?.name?.toLowerCase().includes(search.toLowerCase())
  );

  const totalAmount = form.items.reduce((sum, item) => sum + item.quantity * item.unit_price, 0);

  const getStatusColor = (status: string) => {
    switch (status) {
      case 'approved':
      case 'paid':
        return 'bg-green-900/40 text-green-400';
      case 'rejected':
      case 'cancelled':
        return 'bg-red-900/40 text-red-400';
      case 'pending_approval':
        return 'bg-yellow-900/40 text-yellow-400';
      case 'partially_paid':
        return 'bg-blue-900/40 text-blue-400';
      default:
        return 'bg-gray-800 text-gray-400';
    }
  };

  return (
    <div className="p-8">
      <div className="flex items-center justify-between mb-8">
        <div>
          <h1 className="text-2xl font-bold text-white">Invoices</h1>
          <p className="text-gray-400 mt-1">{state.total} invoices total</p>
        </div>
        <button
          onClick={() => handleOpenModal()}
          className="flex items-center gap-2 bg-blue-600 hover:bg-blue-700 text-white px-4 py-2 rounded-lg text-sm font-medium transition-colors"
        >
          <Plus size={16} />
          Create Invoice
        </button>
      </div>

      <div className="bg-gray-900 rounded-xl border border-gray-800">
        <div className="p-4 border-b border-gray-800">
          <div className="relative">
            <Search size={16} className="absolute left-3 top-1/2 -translate-y-1/2 text-gray-400" />
            <input
              type="text"
              placeholder="Search invoices..."
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
                <th className="text-left text-xs font-medium text-gray-400 px-4 py-3">Invoice #</th>
                <th className="text-left text-xs font-medium text-gray-400 px-4 py-3">Supplier</th>
                <th className="text-left text-xs font-medium text-gray-400 px-4 py-3">Date</th>
                <th className="text-left text-xs font-medium text-gray-400 px-4 py-3">Total</th>
                <th className="text-left text-xs font-medium text-gray-400 px-4 py-3">Paid</th>
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
                    No invoices found
                  </td>
                </tr>
              ) : (
                filtered.map((inv) => (
                  <tr key={inv.id} className="border-b border-gray-800 hover:bg-gray-800/50 transition-colors">
                    <td className="px-4 py-3 text-white text-sm font-medium">{inv.invoice_number}</td>
                    <td className="px-4 py-3 text-gray-400 text-sm">{inv.supplier?.name || '-'}</td>
                    <td className="px-4 py-3 text-gray-400 text-sm">{inv.invoice_date}</td>
                    <td className="px-4 py-3 text-white text-sm font-medium">
                      {inv.currency} {inv.total_amount.toFixed(2)}
                    </td>
                    <td className="px-4 py-3 text-gray-400 text-sm">{inv.paid_amount.toFixed(2)}</td>
                    <td className="px-4 py-3">
                      <span className={`text-xs px-2 py-1 rounded-full ${getStatusColor(inv.status)}`}>
                        {inv.status.replace(/_/g, ' ')}
                      </span>
                    </td>
                    <td className="px-4 py-3">
                      <div className="flex items-center gap-2">
                        {inv.status === 'draft' && (
                          <>
                            <button
                              onClick={() => handleOpenModal(inv)}
                              className="text-gray-500 hover:text-blue-400 transition-colors"
                            >
                              <Edit size={15} />
                            </button>
                            <button
                              onClick={() => setDeleteConfirm({ isOpen: true, id: inv.id })}
                              className="text-gray-500 hover:text-red-400 transition-colors"
                            >
                              <Trash2 size={15} />
                            </button>
                          </>
                        )}
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
          <div className="bg-gray-900 rounded-2xl border border-gray-800 w-full max-w-2xl max-h-[90vh] overflow-y-auto">
            <div className="flex items-center justify-between p-6 border-b border-gray-800">
              <h2 className="text-lg font-semibold text-white">
                {editingId ? 'Edit Invoice' : 'Create Invoice'}
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
              <div className="grid grid-cols-2 gap-4">
                <div>
                  <label className="block text-sm font-medium text-gray-300 mb-1.5">Supplier *</label>
                  <select
                    required
                    value={form.supplier_id}
                    onChange={(e) => setForm({ ...form, supplier_id: e.target.value })}
                    className="w-full bg-gray-800 border border-gray-700 text-white rounded-lg px-4 py-2.5 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500"
                  >
                    <option value="">Select supplier</option>
                    {suppliers.map((s) => (
                      <option key={s.id} value={s.id}>
                        {s.name}
                      </option>
                    ))}
                  </select>
                </div>
                <div>
                  <label className="block text-sm font-medium text-gray-300 mb-1.5">Currency</label>
                  <select
                    value={form.currency}
                    onChange={(e) => setForm({ ...form, currency: e.target.value as any })}
                    className="w-full bg-gray-800 border border-gray-700 text-white rounded-lg px-4 py-2.5 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500"
                  >
                    <option value="USD">USD</option>
                    <option value="EUR">EUR</option>
                    <option value="AED">AED</option>
                    <option value="EGP">EGP</option>
                  </select>
                </div>
              </div>

              <div className="grid grid-cols-2 gap-4">
                <div>
                  <label className="block text-sm font-medium text-gray-300 mb-1.5">Invoice Date *</label>
                  <input
                    required
                    type="date"
                    value={form.invoice_date}
                    onChange={(e) => setForm({ ...form, invoice_date: e.target.value })}
                    className="w-full bg-gray-800 border border-gray-700 text-white rounded-lg px-4 py-2.5 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500"
                  />
                </div>
                <div>
                  <label className="block text-sm font-medium text-gray-300 mb-1.5">Due Date *</label>
                  <input
                    required
                    type="date"
                    value={form.due_date}
                    onChange={(e) => setForm({ ...form, due_date: e.target.value })}
                    className="w-full bg-gray-800 border border-gray-700 text-white rounded-lg px-4 py-2.5 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500"
                  />
                </div>
              </div>

              <div>
                <label className="block text-sm font-medium text-gray-300 mb-1.5">Notes</label>
                <textarea
                  value={form.notes}
                  onChange={(e) => setForm({ ...form, notes: e.target.value })}
                  className="w-full bg-gray-800 border border-gray-700 text-white rounded-lg px-4 py-2.5 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500"
                  placeholder="Additional notes..."
                  rows={2}
                />
              </div>

              {/* Items Section */}
              <div className="border-t border-gray-700 pt-4">
                <div className="flex items-center justify-between mb-3">
                  <h3 className="text-sm font-semibold text-white">Items</h3>
                  <button
                    type="button"
                    onClick={handleAddItem}
                    className="text-xs bg-gray-800 hover:bg-gray-700 text-gray-300 px-2 py-1 rounded transition-colors"
                  >
                    + Add Item
                  </button>
                </div>

                <div className="space-y-2">
                  {form.items.map((item, idx) => (
                    <div key={idx} className="grid grid-cols-12 gap-2 items-end">
                      <input
                        type="text"
                        placeholder="Description"
                        value={item.description}
                        onChange={(e) => handleItemChange(idx, 'description', e.target.value)}
                        className="col-span-5 bg-gray-800 border border-gray-700 text-white rounded px-2 py-1.5 text-xs focus:outline-none focus:ring-2 focus:ring-blue-500"
                      />
                      <input
                        type="number"
                        placeholder="Qty"
                        value={item.quantity}
                        onChange={(e) => handleItemChange(idx, 'quantity', parseFloat(e.target.value))}
                        className="col-span-2 bg-gray-800 border border-gray-700 text-white rounded px-2 py-1.5 text-xs focus:outline-none focus:ring-2 focus:ring-blue-500"
                      />
                      <input
                        type="number"
                        placeholder="Price"
                        value={item.unit_price}
                        onChange={(e) => handleItemChange(idx, 'unit_price', parseFloat(e.target.value))}
                        className="col-span-2 bg-gray-800 border border-gray-700 text-white rounded px-2 py-1.5 text-xs focus:outline-none focus:ring-2 focus:ring-blue-500"
                      />
                      <div className="col-span-2 text-right">
                        <span className="text-xs text-gray-400">
                          ${(item.quantity * item.unit_price).toFixed(2)}
                        </span>
                      </div>
                      <button
                        type="button"
                        onClick={() => handleRemoveItem(idx)}
                        className="col-span-1 text-red-400 hover:text-red-300 text-xs"
                      >
                        ✕
                      </button>
                    </div>
                  ))}
                </div>

                <div className="mt-3 pt-3 border-t border-gray-700 flex justify-end">
                  <div className="text-sm">
                    <span className="text-gray-400">Total: </span>
                    <span className="text-white font-semibold">${totalAmount.toFixed(2)}</span>
                  </div>
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
                  {saving ? 'Saving...' : editingId ? 'Update Invoice' : 'Create Invoice'}
                </button>
              </div>
            </form>
          </div>
        </div>
      )}

      {/* Delete Confirmation */}
      <ConfirmDialog
        isOpen={deleteConfirm.isOpen}
        title="Delete Invoice"
        message="Are you sure you want to delete this invoice? This action cannot be undone."
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
