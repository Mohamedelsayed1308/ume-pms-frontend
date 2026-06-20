'use client';

import { useEffect, useState } from 'react';
import { Plus, Search, Edit, Trash2, X, Check } from 'lucide-react';
import { useCrud } from '@/hooks/useCrud';
import { ConfirmDialog } from '@/components/confirm-dialog';

interface Payment {
  id: string;
  payment_number: string;
  invoice_id: string;
  supplier_id: string;
  payment_date: string;
  amount: number;
  currency: 'USD' | 'EUR' | 'AED' | 'EGP';
  payment_method: 'bank_transfer' | 'check' | 'cash' | 'credit_card';
  bank_account_id?: string;
  reference_number?: string;
  status: 'pending' | 'completed' | 'failed' | 'cancelled';
  notes?: string;
  invoice?: { id: string; invoice_number: string; total_amount: number };
  supplier?: { id: string; name: string };
}

const initialFormState = {
  invoice_id: '',
  supplier_id: '',
  payment_date: new Date().toISOString().split('T')[0],
  amount: 0,
  currency: 'USD' as const,
  payment_method: 'bank_transfer' as const,
  bank_account_id: '',
  reference_number: '',
  notes: '',
};

export default function PaymentsPage() {
  const { state, saving, fetchItems, createItem, updateItem, deleteItem } = useCrud<Payment>({
    baseUrl: '/api/v1/payments',
  });

  const [search, setSearch] = useState('');
  const [showModal, setShowModal] = useState(false);
  const [editingId, setEditingId] = useState<string | null>(null);
  const [form, setForm] = useState(initialFormState);
  const [invoices, setInvoices] = useState<any[]>([]);
  const [suppliers, setSuppliers] = useState<any[]>([]);
  const [deleteConfirm, setDeleteConfirm] = useState<{ isOpen: boolean; id: string | null }>({
    isOpen: false,
    id: null,
  });
  const [actionConfirm, setActionConfirm] = useState<{
    isOpen: boolean;
    id: string | null;
    action: 'complete' | 'cancel' | null;
  }>({
    isOpen: false,
    id: null,
    action: null,
  });

  useEffect(() => {
    fetchItems(1, 50);
    fetch('http://localhost:3001/api/v1/invoices?limit=100')
      .then((r) => r.json())
      .then((d) => setInvoices(d.data || []))
      .catch(() => {});
    fetch('http://localhost:3001/api/v1/suppliers?limit=100')
      .then((r) => r.json())
      .then((d) => setSuppliers(d.data || []))
      .catch(() => {});
  }, []);

  const handleOpenModal = (payment?: Payment) => {
    if (payment) {
      setEditingId(payment.id);
      setForm({
        invoice_id: payment.invoice_id,
        supplier_id: payment.supplier_id,
        payment_date: payment.payment_date,
        amount: payment.amount,
        currency: payment.currency,
        payment_method: payment.payment_method,
        bank_account_id: payment.bank_account_id || '',
        reference_number: payment.reference_number || '',
        notes: payment.notes || '',
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

  const handleAction = async () => {
    if (!actionConfirm.id || !actionConfirm.action) return;
    try {
      const endpoint =
        actionConfirm.action === 'complete'
          ? `/api/v1/payments/${actionConfirm.id}/complete`
          : `/api/v1/payments/${actionConfirm.id}/cancel`;

      const response = await fetch(`http://localhost:3001${endpoint}`, {
        method: 'POST',
        headers: {
          'Authorization': `Bearer ${localStorage.getItem('access_token')}`,
          'Content-Type': 'application/json',
        },
      });

      if (response.ok) {
        fetchItems(1, 50);
        setActionConfirm({ isOpen: false, id: null, action: null });
      }
    } catch (error) {
      // Error handled
    }
  };

  const filtered = state.items.filter(
    (p) =>
      p.payment_number?.toLowerCase().includes(search.toLowerCase()) ||
      p.invoice?.invoice_number?.toLowerCase().includes(search.toLowerCase())
  );

  const getStatusColor = (status: string) => {
    switch (status) {
      case 'completed':
        return 'bg-green-900/40 text-green-400';
      case 'failed':
      case 'cancelled':
        return 'bg-red-900/40 text-red-400';
      case 'pending':
      default:
        return 'bg-yellow-900/40 text-yellow-400';
    }
  };

  return (
    <div className="p-8">
      <div className="flex items-center justify-between mb-8">
        <div>
          <h1 className="text-2xl font-bold text-white">Payments</h1>
          <p className="text-gray-400 mt-1">{state.total} payments total</p>
        </div>
        <button
          onClick={() => handleOpenModal()}
          className="flex items-center gap-2 bg-blue-600 hover:bg-blue-700 text-white px-4 py-2 rounded-lg text-sm font-medium transition-colors"
        >
          <Plus size={16} />
          Create Payment
        </button>
      </div>

      <div className="bg-gray-900 rounded-xl border border-gray-800">
        <div className="p-4 border-b border-gray-800">
          <div className="relative">
            <Search size={16} className="absolute left-3 top-1/2 -translate-y-1/2 text-gray-400" />
            <input
              type="text"
              placeholder="Search payments..."
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
                <th className="text-left text-xs font-medium text-gray-400 px-4 py-3">Payment #</th>
                <th className="text-left text-xs font-medium text-gray-400 px-4 py-3">Invoice</th>
                <th className="text-left text-xs font-medium text-gray-400 px-4 py-3">Supplier</th>
                <th className="text-left text-xs font-medium text-gray-400 px-4 py-3">Amount</th>
                <th className="text-left text-xs font-medium text-gray-400 px-4 py-3">Method</th>
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
                    No payments found
                  </td>
                </tr>
              ) : (
                filtered.map((p) => (
                  <tr key={p.id} className="border-b border-gray-800 hover:bg-gray-800/50 transition-colors">
                    <td className="px-4 py-3 text-white text-sm font-medium">{p.payment_number}</td>
                    <td className="px-4 py-3 text-gray-400 text-sm">{p.invoice?.invoice_number || '-'}</td>
                    <td className="px-4 py-3 text-gray-400 text-sm">{p.supplier?.name || '-'}</td>
                    <td className="px-4 py-3 text-white text-sm font-medium">
                      {p.currency} {p.amount.toFixed(2)}
                    </td>
                    <td className="px-4 py-3">
                      <span className="text-xs bg-gray-800 text-gray-300 px-2 py-1 rounded-full">
                        {p.payment_method.replace(/_/g, ' ')}
                      </span>
                    </td>
                    <td className="px-4 py-3">
                      <span className={`text-xs px-2 py-1 rounded-full ${getStatusColor(p.status)}`}>
                        {p.status}
                      </span>
                    </td>
                    <td className="px-4 py-3">
                      <div className="flex items-center gap-2">
                        {p.status === 'pending' && (
                          <>
                            <button
                              onClick={() => setActionConfirm({ isOpen: true, id: p.id, action: 'complete' })}
                              className="text-gray-500 hover:text-green-400 transition-colors"
                              title="Complete"
                            >
                              <Check size={15} />
                            </button>
                            <button
                              onClick={() => handleOpenModal(p)}
                              className="text-gray-500 hover:text-blue-400 transition-colors"
                            >
                              <Edit size={15} />
                            </button>
                            <button
                              onClick={() => setDeleteConfirm({ isOpen: true, id: p.id })}
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
          <div className="bg-gray-900 rounded-2xl border border-gray-800 w-full max-w-lg max-h-[90vh] overflow-y-auto">
            <div className="flex items-center justify-between p-6 border-b border-gray-800">
              <h2 className="text-lg font-semibold text-white">
                {editingId ? 'Edit Payment' : 'Create Payment'}
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
                <label className="block text-sm font-medium text-gray-300 mb-1.5">Invoice *</label>
                <select
                  required
                  value={form.invoice_id}
                  onChange={(e) => setForm({ ...form, invoice_id: e.target.value })}
                  className="w-full bg-gray-800 border border-gray-700 text-white rounded-lg px-4 py-2.5 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500"
                >
                  <option value="">Select invoice</option>
                  {invoices.map((inv) => (
                    <option key={inv.id} value={inv.id}>
                      {inv.invoice_number} - ${inv.total_amount}
                    </option>
                  ))}
                </select>
              </div>

              <div className="grid grid-cols-2 gap-4">
                <div>
                  <label className="block text-sm font-medium text-gray-300 mb-1.5">Amount *</label>
                  <input
                    required
                    type="number"
                    step="0.01"
                    value={form.amount}
                    onChange={(e) => setForm({ ...form, amount: parseFloat(e.target.value) })}
                    className="w-full bg-gray-800 border border-gray-700 text-white rounded-lg px-4 py-2.5 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500"
                    placeholder="0.00"
                  />
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

              <div>
                <label className="block text-sm font-medium text-gray-300 mb-1.5">Payment Date *</label>
                <input
                  required
                  type="date"
                  value={form.payment_date}
                  onChange={(e) => setForm({ ...form, payment_date: e.target.value })}
                  className="w-full bg-gray-800 border border-gray-700 text-white rounded-lg px-4 py-2.5 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500"
                />
              </div>

              <div>
                <label className="block text-sm font-medium text-gray-300 mb-1.5">Payment Method *</label>
                <select
                  required
                  value={form.payment_method}
                  onChange={(e) => setForm({ ...form, payment_method: e.target.value as any })}
                  className="w-full bg-gray-800 border border-gray-700 text-white rounded-lg px-4 py-2.5 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500"
                >
                  <option value="bank_transfer">Bank Transfer</option>
                  <option value="check">Check</option>
                  <option value="cash">Cash</option>
                  <option value="credit_card">Credit Card</option>
                </select>
              </div>

              <div>
                <label className="block text-sm font-medium text-gray-300 mb-1.5">Reference Number</label>
                <input
                  value={form.reference_number}
                  onChange={(e) => setForm({ ...form, reference_number: e.target.value })}
                  className="w-full bg-gray-800 border border-gray-700 text-white rounded-lg px-4 py-2.5 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500"
                  placeholder="Reference or transaction ID"
                />
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
                  {saving ? 'Saving...' : editingId ? 'Update Payment' : 'Create Payment'}
                </button>
              </div>
            </form>
          </div>
        </div>
      )}

      {/* Delete Confirmation */}
      <ConfirmDialog
        isOpen={deleteConfirm.isOpen}
        title="Delete Payment"
        message="Are you sure you want to delete this payment? This action cannot be undone."
        confirmText="Delete"
        cancelText="Cancel"
        isDangerous={true}
        isLoading={saving}
        onConfirm={handleDelete}
        onCancel={() => setDeleteConfirm({ isOpen: false, id: null })}
      />

      {/* Action Confirmation */}
      <ConfirmDialog
        isOpen={actionConfirm.isOpen}
        title={actionConfirm.action === 'complete' ? 'Complete Payment' : 'Cancel Payment'}
        message={
          actionConfirm.action === 'complete'
            ? 'Mark this payment as completed? This will update the invoice payment status.'
            : 'Cancel this payment? This action cannot be undone.'
        }
        confirmText={actionConfirm.action === 'complete' ? 'Complete' : 'Cancel'}
        cancelText="Close"
        isDangerous={actionConfirm.action === 'cancel'}
        isLoading={saving}
        onConfirm={handleAction}
        onCancel={() => setActionConfirm({ isOpen: false, id: null, action: null })}
      />
    </div>
  );
}
