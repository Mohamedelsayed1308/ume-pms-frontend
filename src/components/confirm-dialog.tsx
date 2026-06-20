'use client';

import { AlertCircle, X } from 'lucide-react';

interface ConfirmDialogProps {
  isOpen: boolean;
  title: string;
  message: string;
  confirmText?: string;
  cancelText?: string;
  isDangerous?: boolean;
  isLoading?: boolean;
  onConfirm: () => void;
  onCancel: () => void;
}

export function ConfirmDialog({
  isOpen,
  title,
  message,
  confirmText = 'Confirm',
  cancelText = 'Cancel',
  isDangerous = false,
  isLoading = false,
  onConfirm,
  onCancel,
}: ConfirmDialogProps) {
  if (!isOpen) return null;

  return (
    <div className="fixed inset-0 bg-black/60 flex items-center justify-center z-50 p-4">
      <div className="bg-gray-900 rounded-2xl border border-gray-800 w-full max-w-sm">
        <div className="flex items-center justify-between p-6 border-b border-gray-800">
          <div className="flex items-center gap-3">
            <AlertCircle size={20} className={isDangerous ? 'text-red-400' : 'text-blue-400'} />
            <h2 className="text-lg font-semibold text-white">{title}</h2>
          </div>
          <button
            onClick={onCancel}
            disabled={isLoading}
            className="text-gray-400 hover:text-white disabled:opacity-50"
          >
            <X size={20} />
          </button>
        </div>

        <div className="p-6">
          <p className="text-gray-300 text-sm">{message}</p>
        </div>

        <div className="flex gap-3 p-6 border-t border-gray-800">
          <button
            onClick={onCancel}
            disabled={isLoading}
            className="flex-1 bg-gray-800 hover:bg-gray-700 disabled:bg-gray-800 disabled:opacity-50 text-white py-2.5 rounded-lg text-sm font-medium transition-colors"
          >
            {cancelText}
          </button>
          <button
            onClick={onConfirm}
            disabled={isLoading}
            className={`flex-1 py-2.5 rounded-lg text-sm font-medium transition-colors disabled:opacity-50 text-white ${
              isDangerous
                ? 'bg-red-600 hover:bg-red-700 disabled:bg-red-800'
                : 'bg-blue-600 hover:bg-blue-700 disabled:bg-blue-800'
            }`}
          >
            {isLoading ? 'Processing...' : confirmText}
          </button>
        </div>
      </div>
    </div>
  );
}
